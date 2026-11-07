--[=[
    ================================================================================
    MULTI-BIOME STRIKE SWAPPER
    ================================================================================
    User Workflow:
      1. Manual pick up an egg in Forest biome.
      2. Teleport to Target Biome Egg (replacing Pen) via Hit Authority and drop
         the Forest egg.
      3. Pick up the egg on Target Biome Egg and return back to Forest biome
         to drop the egg.
      4. Return to SafeZone after re-picking up the egg in Forest.

    Safety & Cleanliness:
      - Zero Metamethod Hooks: No __namecall or __index hooks (zero kicks).
      - No Random Teleports: Waits passively in IDLE for manual Forest egg pickup.
      - Robust Pickup: Direct AreaEggSlotsClient + SmartPromptPart indexing.
      - Root Locals Budget: Strictly <= 20 (15 root locals).
    ================================================================================
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer and LocalPlayer.Character
local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
local RootPart = Character and (Character:FindFirstChild("HumanoidRootPart") or Character.PrimaryPart)

local Config = {
    GuiName = "MultiBiomeDropperGui",
    DropSpamCount = 8,
    DropSpamInterval = 0.03,
    PositionSettleTime = 0.30,
    StrikeTimeout = 2.50,
    ReturnDelay = 0.50,
    NestScanRadius = 50.0,
    MaxLogs = 300,
    Biomes = {
        "Enchanted Forest",
        "Cherry Blossom",
        "Titan Temple",
        "Cosmic",
        "Prehistoric",
        "Volcano",
        "Desert",
        "Snow",
        "Jungle",
        "Abyss Ocean",
        "Lake",
        "Light Dark",
        "Forest",
    },
    BiomeNestFallbacks = {
        ["Enchanted Forest"] = Vector3.new(6700.8, 71.5, -353.8),
        ["Cherry Blossom"]  = Vector3.new(4031.5, 71.0, -392.4),
        ["Titan Temple"]    = Vector3.new(4790.8, 71.5, -326.7),
        ["Cosmic"]          = Vector3.new(3395.0, 71.0, -329.2),
        ["Prehistoric"]     = Vector3.new(2813.6, 71.0, -402.2),
        ["Volcano"]         = Vector3.new(1883.4, 71.0, -393.8),
        ["Desert"]          = Vector3.new(943.2, 71.0, -321.4),
        ["Snow"]            = Vector3.new(1488.2, 75.0, -318.8),
        ["Jungle"]          = Vector3.new(1193.2, 71.0, -405.3),
        ["Abyss Ocean"]     = Vector3.new(2281.6, 71.0, -323.1),
        ["Lake"]            = Vector3.new(735.9, 71.0, -410.7),
        ["Light Dark"]      = Vector3.new(5662.2, 71.5, -324.7),
        ["Forest"]          = Vector3.new(596.7, 71.4, -327.8),
    },
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

local Phases = {
    IDLE = "IDLE",
    OUTBOUND_TO_TARGET_BIOME = "OUTBOUND_TO_TARGET_BIOME",
    PICKUP_BIOME_EGG = "PICKUP_BIOME_EGG",
    RETURN_TO_FOREST = "RETURN_TO_FOREST",
    REPICKUP_TO_SAFEZONE = "REPICKUP_TO_SAFEZONE",
}

local State = {
    Enabled = true,
    AutoLoop = true,
    CurrentPhase = Phases.IDLE,
    SelectedBiomeIndex = 1,
    TargetBiome = Config.Biomes[1],
    -- 1. Target Biome Egg (Replaces Pen as first destination)
    TargetBiomeLocation = Config.BiomeNestFallbacks["Enchanted Forest"],
    StartLocation = Config.BiomeNestFallbacks["Enchanted Forest"], -- Alias for tests
    -- 2. Forest Location (Where we pick up initial egg & return to drop biome egg)
    ForestLocation = Vector3.new(596.7, 71.4, -327.8),
    ForestDropLocation = Vector3.new(596.7, 71.4, -327.8), -- Alias for tests
    SavedLocation = Vector3.new(596.7, 71.4, -327.8),     -- Alias for tests
    -- 3. SafeZone Location (Where we return after re-picking up)
    SafeZoneLocation = Vector3.new(542.9, 71.4, -318.7),
    IsActive = false,
    IsCarrying = false,
    CurrentEggUid = nil,
    ForestEggUid = nil,
    TargetEggUid = nil,
    CarriedUid = nil,
    TargetEggRepicked = false,
    Deliveries = 0,
    Logs = {},
}
State.AutoLoop = true

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
    if net then
        return net:FindFirstChild(path)
    end
    return nil
end

Remotes.FieldCarry = Helpers.getNetRemote("RE/EggWorld/FieldEggCarry")
Remotes.ForestStrike = Helpers.getNetRemote("RE/GuardPatrol/ForestStrike")
Remotes.Rouse = Helpers.getNetRemote("RE/GuardPatrol/Rouse")
Remotes.SpeedTollOffer = Helpers.getNetRemote("RE/GuardPatrol/SpeedTollOffer")
Remotes.RigRefresh = Helpers.getNetRemote("RE/RigSync/Refresh")
Remotes.AskDrop = Helpers.getNetRemote("RF/EggWorld/AskFieldEggDrop")
Remotes.AskCarry = Helpers.getNetRemote("RF/EggWorld/AskFieldEggCarry")

-- Multi-Biome Target Egg Resolution
Helpers.getBiomeNestPosition = function(biomeName)
    local ws = workspace
    local areas = ws:FindFirstChild("World") and ws.World:FindFirstChild("Areas")
    local guardAreas = areas and areas:FindFirstChild("GuardAreas")
    if guardAreas then
        local biomeFolder = guardAreas:FindFirstChild(biomeName)
            or (biomeName == "Light Dark" and guardAreas:FindFirstChild("Light & Dark"))
        if biomeFolder then
            local nests = biomeFolder:FindFirstChild("Nests")
            if nests then
                for _, n in ipairs(nests:GetChildren()) do
                    if n:IsA("Model") then
                        local spot = n:FindFirstChild("EggSpotBottom") or n:FindFirstChild("EggFitBounds")
                        if spot and spot:IsA("BasePart") then
                            return spot.Position + Vector3.new(0, 3, 0)
                        end
                        local ok, piv = pcall(function() return n:GetPivot().Position end)
                        if ok and piv then return piv + Vector3.new(0, 3, 0) end
                    end
                end
            end
            local guard = biomeFolder:FindFirstChild("Guard") or biomeFolder:FindFirstChild("ForestGuardAuthored")
            if guard then
                local ok, piv = pcall(function() return guard:GetPivot().Position end)
                if ok and piv then return piv + Vector3.new(0, 3, 0) end
            end
        end
    end
    if Config.BiomeNestFallbacks and Config.BiomeNestFallbacks[biomeName] then
        return Config.BiomeNestFallbacks[biomeName]
    end
    return nil
end

Helpers.getClosestGuard = function(playerPos)
    local bestGuard = nil
    local bestDist = math.huge
    local bestAreaName = "Forest"
    local ws = workspace
    local areas = ws:FindFirstChild("World") and ws.World:FindFirstChild("Areas")
    local guardAreas = areas and areas:FindFirstChild("GuardAreas")
    if guardAreas then
        for _, area in ipairs(guardAreas:GetChildren()) do
            local guard = area:FindFirstChild("Guard") or area:FindFirstChild("ForestGuardAuthored")
            if guard then
                local pivot = guard:GetPivot()
                local dist = (pivot.Position - playerPos).Magnitude
                if dist < bestDist then
                    bestDist = dist
                    bestGuard = guard
                    bestAreaName = area.Name
                end
            end
        end
    end
    return bestGuard, bestAreaName, bestDist
end

Helpers.getBiomeGuard = function(biomeName)
    local ws = workspace
    local areas = ws:FindFirstChild("World") and ws.World:FindFirstChild("Areas")
    local guardAreas = areas and areas:FindFirstChild("GuardAreas")
    if guardAreas and biomeName then
        local area = guardAreas:FindFirstChild(biomeName)
            or (biomeName == "Light Dark" and guardAreas:FindFirstChild("Light & Dark"))
        if area then
            local g = area:FindFirstChild("Guard") or area:FindFirstChild("ForestGuardAuthored")
            if g then
                local pivot = g:GetPivot()
                local dist = RootPart and (pivot.Position - RootPart.Position).Magnitude or 0
                return g, area.Name, dist
            end
        end
    end
    return Helpers.getClosestGuard(RootPart and RootPart.Position or Vector3.zero)
end

Helpers.rouseGuard = function(guard, areaName)
    local event = Remotes.Rouse or Helpers.getNetRemote("RE/GuardPatrol/Rouse")
    if event and guard then
        pcall(function()
            if typeof(firesignal) == "function" then
                firesignal(event.OnClientEvent, guard, areaName)
            elseif typeof(getconnections) == "function" then
                for _, conn in ipairs(getconnections(event.OnClientEvent)) do
                    if conn.Function then
                        task.spawn(conn.Function, guard, areaName)
                    elseif conn.Fire then
                        conn:Fire(guard, areaName)
                    end
                end
            end
        end)
    end
end

Helpers.getForestGuard = function()
    local ws = workspace
    local guard = ws:FindFirstChild("World", true)
    if guard then
        local fg = guard:FindFirstChild("ForestGuardAuthored", true)
            or guard:FindFirstChild("Forest", true)
        if fg then return fg end
    end
    local areas = ws:FindFirstChild("World") and ws.World:FindFirstChild("Areas")
    local guardAreas = areas and areas:FindFirstChild("GuardAreas")
    if guardAreas then
        local fa = guardAreas:FindFirstChild("Forest")
        if fa then
            local g = fa:FindFirstChild("Guard") or fa:FindFirstChild("ForestGuardAuthored")
            if g then return g end
        end
    end
    return nil
end

Helpers.getForestGuardCFrame = function()
    local fg = Helpers.getForestGuard()
    if fg then
        local p = fg:GetPivot()
        if p then return p end
    end
    return Config.SampleGuardCFrame
end

Helpers.getForestEggUid = function()
    if State.ForestEggUid and string.find(tostring(State.ForestEggUid), "Forest", 1, true) then
        return State.ForestEggUid
    end
    if State.CurrentEggUid and string.find(tostring(State.CurrentEggUid), "Forest", 1, true) then
        return State.CurrentEggUid
    end
    local slots = workspace:FindFirstChild("AreaEggSlotsClient")
    if slots then
        for _, sl in ipairs(slots:GetChildren()) do
            if string.find(string.lower(sl.Name), "_forest:slot_", 1, true) then
                return sl.Name
            end
        end
    end
    return "FirstAreaEgg_11924439055_5979114_Forest:Slot_001"
end

-- Proximity Prompt Filtering & Activation (Prevents opening Hatch / Shop / Dialog UIs)
Helpers.isCarryPrompt = function(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") or not prompt.Enabled then return false end
    local n = (prompt.Name or ""):lower()
    local a = (prompt.ActionText or ""):lower()
    local o = (prompt.ObjectText or ""):lower()

    for _, bl in ipairs({ "shop", "hatch", "buy", "purchase", "open", "talk", "dialog", "manor", "trade", "pet" }) do
        if n:find(bl, 1, true) or a:find(bl, 1, true) or o:find(bl, 1, true) then
            return false
        end
    end
    if n:find("carry", 1, true) or n:find("steal", 1, true) or n:find("pickup", 1, true) or n:find("egg", 1, true) then
        return true
    end
    if a:find("carry", 1, true) or a:find("steal", 1, true) or a:find("pick", 1, true) or a:find("take", 1, true) or a:find("grab", 1, true) then
        return true
    end
    return false
end

Helpers.triggerPrompt = function(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end
    if not Helpers.isCarryPrompt(prompt) then return false end
    local ok = pcall(function()
        if typeof(fireproximityprompt) == "function" then
            pcall(function() fireproximityprompt(prompt, 1) end)
            pcall(function() fireproximityprompt(prompt, 0) end)
            pcall(function() fireproximityprompt(prompt) end)
        elseif prompt.InputHoldBegin then
            prompt:InputHoldBegin()
            task.wait(prompt.HoldDuration or 0)
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

-- Egg Drop Remote Invocation (Spams drop, waits for server FieldEggCarry { IsCarrying = false })
Engine.dropEggSpam = function(count)
    count = count or Config.DropSpamCount or 8
    local rf = Remotes.AskDrop or Helpers.getNetRemote("RF/EggWorld/AskFieldEggDrop")
    if not rf then
        Helpers.log("ERROR: AskFieldEggDrop remote not found", "ERROR")
        return false
    end

    local dropped = false
    for i = 1, count do
        if not State.IsCarrying then
            dropped = true
            break
        end

        local sendPos = RootPart and RootPart.Parent and RootPart.Position
        local ok, res = pcall(function()
            return rf:InvokeServer({ Reason = "PlayerRequest" })
        end)
        if not ok or res == false then
            pcall(function() rf:InvokeServer() end)
        end
        local statusStr = ok and tostring(res) or ("ERROR: " .. tostring(res))
        Helpers.log(string.format("AskFieldEggDrop [#%d/%d] returned: %s%s",
            i, count, statusStr,
            sendPos and string.format(" | pos=(%.1f, %.1f, %.1f)", sendPos.X, sendPos.Y, sendPos.Z) or ""
        ), "DROP")

        -- Wait up to 0.15s for server to fire FieldEggCarry { IsCarrying = false }
        local pollStart = os.clock()
        while (os.clock() - pollStart < 0.15) and State.IsCarrying do
            RunService.Heartbeat:Wait()
        end

        if not State.IsCarrying then
            dropped = true
            break
        end

        if i < count then
            task.wait(Config.DropSpamInterval)
        end
    end

    -- Extra replication window if needed
    if not dropped and State.IsCarrying then
        local waitDrop = os.clock()
        while State.IsCarrying and (os.clock() - waitDrop < 0.35) do
            RunService.Heartbeat:Wait()
        end
        if not State.IsCarrying then
            dropped = true
        end
    end

    return not State.IsCarrying
end

-- Synchronous & Verified Egg Drop (Waits until server confirms drop)
Engine.dropEggSync = function(timeout)
    timeout = timeout or 2.0
    local rf = Remotes.AskDrop or Helpers.getNetRemote("RF/EggWorld/AskFieldEggDrop")
    if not rf then
        Helpers.log("ERROR: AskFieldEggDrop remote not found", "ERROR")
        return false
    end

    if not State.IsCarrying then
        Helpers.log("⚠️ Drop skipped: Not carrying any egg!", "WARN")
        return false
    end

    Helpers.nullifyRagdoll()
    if RootPart and RootPart.Parent then
        RootPart.AssemblyLinearVelocity = Vector3.zero
        RootPart.AssemblyAngularVelocity = Vector3.zero
    end

    local dropStart = os.clock()
    local attempt = 0
    local maxAttempts = 10

    while (os.clock() - dropStart < timeout) and State.IsCarrying and attempt < maxAttempts do
        attempt = attempt + 1
        local ok, res = pcall(function()
            return rf:InvokeServer({ Reason = "PlayerRequest" })
        end)
        Helpers.log(string.format("AskFieldEggDrop [#%d] returned: %s (ok=%s)", attempt, tostring(res), tostring(ok)), "DROP")

        -- Wait up to 0.15s for server to fire FieldEggCarry { IsCarrying = false }
        local pollStart = os.clock()
        while (os.clock() - pollStart < 0.15) and State.IsCarrying do
            RunService.Heartbeat:Wait()
        end

        if not State.IsCarrying then
            break
        end
    end

    local myPos = RootPart and RootPart.Position or Vector3.zero
    local forestPos = State.ForestLocation or Vector3.new(596.7, 71.4, -327.8)
    local inForest = (myPos - forestPos).Magnitude <= 150.0

    local dropped = (not State.IsCarrying) and inForest
    if dropped then
        Helpers.log(string.format("✓ Egg dropped successfully in Forest (+%.3fs, %d attempts)!", os.clock() - dropStart, attempt), "DROP")
    else
        if not inForest then
            Helpers.log(string.format("⚠️ Drop failed: Character not in Forest (dist=%.1f studs). Rubberband detected!", (myPos - forestPos).Magnitude), "WARN")
        else
            Helpers.log(string.format("⚠️ Egg drop timeout in Forest after %.3fs (%d attempts). Still carrying: %s", os.clock() - dropStart, attempt, tostring(State.IsCarrying)), "WARN")
        end
    end
    return dropped
end

-- Robust Egg Finding and Pickup (AreaEggSlotsClient + SmartPromptPart)
Helpers.tryPickupNearbyEgg = function(centerPos, radius, excludeUid)
    radius = radius or Config.NestScanRadius or 50.0
    centerPos = centerPos or (RootPart and RootPart.Position)
    if not centerPos then return false end

    local rfCarry = Remotes.AskCarry or Helpers.getNetRemote("RF/EggWorld/AskFieldEggCarry")
    local ws = workspace
    local candidatePrompts = {}
    local candidateUids = {}

    -- 1. Scan AreaEggSlotsClient (Primary egg container across all biomes)
    local slotsFolder = ws:FindFirstChild("AreaEggSlotsClient")
        or (ws:FindFirstChild("World") and ws.World:FindFirstChild("Areas") and ws.World.Areas:FindFirstChild("EggSlotsClient"))
    if slotsFolder then
        for _, sl in ipairs(slotsFolder:GetChildren()) do
            local p = (sl:IsA("BasePart") and sl.Position)
                or (sl:IsA("Model") and (sl.PrimaryPart and sl.PrimaryPart.Position or sl:GetPivot().Position))
            if p and (p - centerPos).Magnitude <= radius then
                local uid = sl.Name
                local attrUid = sl:GetAttribute("Uid") or sl:GetAttribute("EggUid")
                if attrUid and typeof(attrUid) == "string" and #attrUid > 0 then
                    uid = attrUid
                end

                -- Exclude dropped Forest egg when picking up biome egg
                local isExcluded = (excludeUid and uid == excludeUid)
                if State.TargetBiome and State.TargetBiome ~= "Forest" and string.find(tostring(uid), "Forest", 1, true) then
                    isExcluded = true
                end

                if not isExcluded then
                    table.insert(candidateUids, uid)

                    local pr = sl:FindFirstChildWhichIsA("ProximityPrompt", true)
                    if pr and Helpers.isCarryPrompt(pr) then
                        table.insert(candidatePrompts, pr)
                    end
                end
            end
        end
    end

    -- 2. Scan SmartPromptPart (The game's dynamic carry prompt)
    local spp = ws:FindFirstChild("SmartPromptPart")
    if spp then
        for _, pr in ipairs(spp:GetDescendants()) do
            if pr:IsA("ProximityPrompt") and Helpers.isCarryPrompt(pr) then
                table.insert(candidatePrompts, pr)
            end
        end
    end

    -- Trigger verified candidate prompts (Filtered: ZERO hatch / shop prompts)
    for _, prompt in ipairs(candidatePrompts) do
        Helpers.triggerPrompt(prompt)
    end

    -- Invoke carry remote on candidate UIDs
    if rfCarry then
        for _, uid in ipairs(candidateUids) do
            task.spawn(function()
                local ok, res = pcall(function()
                    return rfCarry:InvokeServer({ Uid = uid })
                end)
                if not ok or res == false then
                    if State.TargetBiome then
                        pcall(function()
                            rfCarry:InvokeServer({
                                FirstAreaSlotKey = State.TargetBiome .. ":" .. uid,
                                Uid = uid,
                            })
                        end)
                    end
                end
            end)
        end
    end

    return (#candidatePrompts > 0 or #candidateUids > 0)
end

-- Targeted Dropped Biome Egg Re-Pickup (Step 4)
-- Strictly requests targetUid only; never requests Forest slot eggs
Helpers.repickupTargetEgg = function(targetUid, dropPos)
    if not targetUid or targetUid == "" then return false end
    local ws = workspace
    local rfCarry = Remotes.AskCarry or Helpers.getNetRemote("RF/EggWorld/AskFieldEggCarry")

    -- 1. Ensure character stays positioned right on the dropped egg
    if RootPart and RootPart.Parent and dropPos then
        if (RootPart.Position - dropPos).Magnitude > 2.0 then
            RootPart.CFrame = CFrame.new(dropPos)
            RootPart.AssemblyLinearVelocity = Vector3.zero
            RootPart.AssemblyAngularVelocity = Vector3.zero
        end
    end

    -- 2. Direct remote invocation on targetUid
    if rfCarry then
        task.spawn(function()
            local ok, res = pcall(function()
                return rfCarry:InvokeServer({ Uid = targetUid })
            end)
            if ok and res == true then
                State.IsCarrying = true
                State.TargetEggRepicked = true
                Helpers.log(string.format("✓ AskFieldEggCarry returned true for %s!", tostring(targetUid)), "SAFEZONE")
            else
                pcall(function()
                    rfCarry:InvokeServer({
                        FirstAreaSlotKey = State.TargetBiome .. ":" .. targetUid,
                        Uid = targetUid,
                    })
                end)
            end
        end)
    end

    -- 3. Dynamic SmartPromptPart (Game's dynamic carry prompt)
    local spp = ws:FindFirstChild("SmartPromptPart")
    if spp then
        for _, pr in ipairs(spp:GetDescendants()) do
            if pr:IsA("ProximityPrompt") and Helpers.isCarryPrompt(pr) then
                Helpers.triggerPrompt(pr)
            end
        end
    end

    -- 4. Search for dropped target egg instance in Workspace containers
    local eggInst = nil
    local slotsFolder = ws:FindFirstChild("AreaEggSlotsClient")
    if slotsFolder then
        eggInst = slotsFolder:FindFirstChild(targetUid)
    end
    if not eggInst then
        local eggsFolder = ws:FindFirstChild("Eggs")
        if eggsFolder then
            eggInst = eggsFolder:FindFirstChild(targetUid)
        end
    end
    if not eggInst then
        local cra = ws:FindFirstChild("ClientRenderedAssets")
        if cra then
            for _, ch in ipairs(cra:GetChildren()) do
                if string.find(ch.Name, targetUid, 1, true) then
                    eggInst = ch
                    break
                end
            end
        end
    end

    if eggInst then
        for _, pr in ipairs(eggInst:GetDescendants()) do
            if pr:IsA("ProximityPrompt") and Helpers.isCarryPrompt(pr) then
                Helpers.triggerPrompt(pr)
            end
        end
    end

    return true
end

-- ============================================================================
-- 4-STEP CORE WORKFLOW
-- 1. Manual pick up on Forest biome
-- 2. Teleport to Target Biome Egg (replacing Pen) & drop Forest egg
-- 3. Pick up Target Biome egg & return back to Forest biome to drop it
-- 4. Return to SafeZone after re-pickup
-- ============================================================================

-- Step 1 & 2: Forest Egg Picked -> Strike -> Teleport to Target Biome Egg -> Drop Forest Egg
Engine.handleForestPickup = function(eggUid)
    if not State.Enabled or State.IsActive then return end
    State.IsActive = true
    State.CurrentPhase = Phases.OUTBOUND_TO_TARGET_BIOME
    State.CurrentEggUid = eggUid
    State.ForestEggUid = eggUid

    if RootPart and RootPart.Parent then
        local myPos = RootPart.Position
        if (myPos - (State.ForestLocation or Vector3.new(596.7, 71.4, -327.8))).Magnitude <= 200.0 then
            State.ForestLocation = myPos
        end
    end

    if _G.DropperTargetEggPos then
        State.TargetBiomeLocation = _G.DropperTargetEggPos
    end
    if _G.DropperTargetBiome then
        State.TargetBiome = _G.DropperTargetBiome
    end

    local targetEggPos = State.TargetBiomeLocation or Helpers.getBiomeNestPosition(State.TargetBiome)
    if not targetEggPos then
        UI.setStatus("Error: Target Biome Egg position unknown!", Config.Theme.Red)
        State.IsActive = false
        State.CurrentPhase = Phases.IDLE
        return
    end

    UI.setStatus(string.format("Forest Egg Picked! Teleporting to %s Egg...", State.TargetBiome), Config.Theme.Cyan)
    Helpers.log(string.format("Manual Forest pickup: %s. Teleporting to %s egg at V3(%.1f, %.1f, %.1f)",
        tostring(eggUid), State.TargetBiome, targetEggPos.X, targetEggPos.Y, targetEggPos.Z), "OUTBOUND")

    local startTime = os.clock()

    -- 1. Fire ForestStrike to obtain strike packet
    local strikeRemote = Remotes.ForestStrike or Helpers.getNetRemote("RE/GuardPatrol/ForestStrike")
    if strikeRemote then
        pcall(function()
            strikeRemote:FireServer({
                GuardCFrame = Config.SampleGuardCFrame,
                EggUid = eggUid,
            })
        end)
        Helpers.log("ForestStrike sent to server.", "STRIKE")
    end

    -- 2. Listen for Server Strike Packet (SpeedTollOffer)
    local strikeConfirmed = false
    local strikeConns = {}

    local function onOutboundStrike()
        if strikeConfirmed then return end
        strikeConfirmed = true
        for _, c in ipairs(strikeConns) do pcall(function() c:Disconnect() end) end
        table.clear(strikeConns)

        Helpers.log(string.format("Strike confirmed (+%.3fs)! Teleporting to %s egg...", os.clock() - startTime, State.TargetBiome), "STRIKE")

        -- Step 2: Teleport directly to Target Biome Egg
        if RootPart and RootPart.Parent then
            RootPart.CFrame = CFrame.new(targetEggPos + Vector3.new(0, 2.5, 0))
            RootPart.AssemblyLinearVelocity = Vector3.zero
            RootPart.AssemblyAngularVelocity = Vector3.zero
        end

        Helpers.nullifyRagdoll()

        -- Drop the Forest egg at Target Biome
        task.spawn(function()
            Engine.dropEggSpam(Config.DropSpamCount)
        end)

        -- Settle at Target Biome
        local settleStart = os.clock()
        while (os.clock() - settleStart < Config.PositionSettleTime) do
            if RootPart and RootPart.Parent then
                RootPart.CFrame = CFrame.new(targetEggPos + Vector3.new(0, 2.5, 0))
                RootPart.AssemblyLinearVelocity = Vector3.zero
            end
            RunService.Heartbeat:Wait()
        end

        UI.setStatus(string.format("At %s! Picking up %s egg...", State.TargetBiome, State.TargetBiome), Config.Theme.Cyan)
        Helpers.log(string.format("Arrived at %s egg. Dropped Forest egg.", State.TargetBiome), "ARRIVED")

        State.IsActive = false
        State.IsCarrying = false

        -- Proceed to Step 3: Pick up Target Biome egg
        task.delay(0.35, function()
            Engine.handleBiomeEggPickup(targetEggPos)
        end)
    end

    if Remotes.SpeedTollOffer then
        table.insert(strikeConns, Remotes.SpeedTollOffer.OnClientEvent:Connect(onOutboundStrike))
    end
    if Remotes.RigRefresh then
        table.insert(strikeConns, Remotes.RigRefresh.OnClientEvent:Connect(function(json)
            if typeof(json) == "string" and string.find(json, "Ragdoll", 1, true) then
                onOutboundStrike()
            end
        end))
    end
    if Character then
        table.insert(strikeConns, Character.AttributeChanged:Connect(function(attr)
            if attr == "RagdollEndTime" and (Character:GetAttribute("RagdollEndTime") or 0) > 0 then
                onOutboundStrike()
            end
        end))
    end

    task.delay(Config.StrikeTimeout, function()
        if not strikeConfirmed then
            for _, c in ipairs(strikeConns) do pcall(function() c:Disconnect() end) end
            table.clear(strikeConns)
            State.IsActive = false
            State.CurrentPhase = Phases.IDLE
            UI.setStatus("Timeout: Strike packet did not arrive in Forest.", Config.Theme.Yellow)
            Helpers.log("Outbound strike timeout expired.", "WARN")
        end
    end)
end

-- Step 3 Part A: Pick up the egg on Target Biome Egg
Engine.handleBiomeEggPickup = function(targetEggPos)
    if not State.Enabled or State.IsActive then return end
    State.CurrentPhase = Phases.PICKUP_BIOME_EGG
    UI.setStatus(string.format("Scanning for %s egg...", State.TargetBiome), Config.Theme.Cyan)
    Helpers.log(string.format("Looking for egg in %s nest...", State.TargetBiome), "PICKUP")

    task.spawn(function()
        local attempts = 0
        while attempts < 25 and not State.IsCarrying and State.CurrentPhase == Phases.PICKUP_BIOME_EGG do
            attempts = attempts + 1
            Helpers.tryPickupNearbyEgg(targetEggPos, Config.NestScanRadius or 50.0, State.CurrentEggUid)
            task.wait(0.20)
        end

        if not State.IsCarrying and State.CurrentPhase == Phases.PICKUP_BIOME_EGG then
            UI.setStatus(string.format("Waiting for %s egg to spawn...", State.TargetBiome), Config.Theme.Yellow)
            Helpers.log(string.format("Waiting for %s egg to spawn...", State.TargetBiome), "WARN")
        end
    end)
end

-- Step 2: Target Biome Egg Picked -> Return Drop Sequence (like dropper.lua & drop-13.log)
Engine.handleReturnToForest = function(biomeEggUid)
    if not State.Enabled or State.IsActive then return end
    State.IsActive = true
    State.CurrentPhase = Phases.RETURN_TO_FOREST
    State.TargetEggUid = biomeEggUid

    local forestPos = State.ForestLocation or Vector3.new(596.7, 71.4, -327.8)
    State.SavedLocation = forestPos

    UI.setStatus(string.format("Carrying %s Egg! Returning to Forest (Drop Sequence)...", State.TargetBiome), Config.Theme.Cyan)
    Helpers.log(string.format("Carrying %s egg (%s). Starting return drop sequence...",
        State.TargetBiome, tostring(biomeEggUid)), "INBOUND")

    local forestEggUid = State.ForestEggUid or Helpers.getForestEggUid()
    local guardCFrame = Helpers.getForestGuardCFrame()

    -- 1. FOREST STRIKE TRIGGER (Exact dropper.lua pattern)
    local strikeRemote = Remotes.ForestStrike or Helpers.getNetRemote("RE/GuardPatrol/ForestStrike")
    if strikeRemote then
        pcall(function()
            strikeRemote:FireServer({
                GuardCFrame = guardCFrame,
                EggUid = forestEggUid,
            })
        end)
        Helpers.log(string.format("ForestStrike sent for return (EggUid=%s)", tostring(forestEggUid)), "STRIKE")
    end

    task.wait(0.05)

    -- 2. DROP POSITION (Set directly to location, NO flying down!)
    if RootPart and RootPart.Parent then
        RootPart.CFrame = CFrame.new(State.SavedLocation)
        RootPart.AssemblyLinearVelocity = Vector3.zero
        RootPart.AssemblyAngularVelocity = Vector3.zero
    end

    Helpers.nullifyRagdoll()

    -- 3. HOLD / REPLICATING POSITION (0.30s as in dropper.lua)
    local settleTime = Config.PositionSettleTime or 0.30
    local settleStart = os.clock()
    while (os.clock() - settleStart < settleTime) do
        if RootPart and RootPart.Parent then
            RootPart.CFrame = CFrame.new(State.SavedLocation)
            RootPart.AssemblyLinearVelocity = Vector3.zero
            RootPart.AssemblyAngularVelocity = Vector3.zero
        end
        RunService.Heartbeat:Wait()
    end

    -- 4. STATE: FREEFALL (As in dropper.lua)
    if Humanoid and Humanoid.Parent then
        pcall(function()
            Humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
        end)
    end

    -- 5. DROP REMOTE AT FOREST LOCATION (Holding location, NO flying down!)
    local dropped = Engine.dropEggSpam(Config.DropSpamCount or 8)

    -- Pin position at location to prevent flinging or rubberbanding
    if RootPart and RootPart.Parent then
        RootPart.CFrame = CFrame.new(State.SavedLocation)
        RootPart.AssemblyLinearVelocity = Vector3.zero
        RootPart.AssemblyAngularVelocity = Vector3.zero
    end
    Helpers.nullifyRagdoll()

    -- Strict check: Did the egg actually drop?
    if not dropped or State.IsCarrying then
        UI.setStatus("❌ Error: Egg failed to drop in Forest!", Config.Theme.Red)
        Helpers.log("Drop failed in Forest: Server did not drop egg. Step 4 aborted.", "ERROR")
        State.IsActive = false
        State.CurrentPhase = Phases.IDLE
        return
    end

    -- Restore Running state so Humanoid can interact with ProximityPrompts
    if Humanoid and Humanoid.Parent and Humanoid.Health > 0 then
        pcall(function()
            Humanoid:ChangeState(Enum.HumanoidStateType.Running)
        end)
    end

    UI.setStatus(string.format("✓ At Forest! Dropped %s egg on ground.", State.TargetBiome), Config.Theme.Green)
    Helpers.log(string.format("Arrived in Forest. Dropped %s egg. Waiting for egg to settle...", State.TargetBiome), "ARRIVED")

    State.IsActive = false
    State.IsCarrying = false

    -- 6. Pause to let egg settle on Forest ground, then re-pickup and deliver to SafeZone
    task.wait(0.50)
    Engine.handleRepickupAndReturnToSafezone(biomeEggUid, forestPos)
end

-- Step 4: Return to SafeZone After Repick up
Engine.handleRepickupAndReturnToSafezone = function(targetEggUid, forestPos)
    if not State.Enabled then return end
    targetEggUid = targetEggUid or State.TargetEggUid
    forestPos = forestPos or State.ForestLocation or Vector3.new(596.7, 71.4, -327.8)
    State.IsActive = true
    State.CurrentPhase = Phases.REPICKUP_TO_SAFEZONE
    State.TargetEggRepicked = false
    State.IsCarrying = false

    -- Guard: If somehow still carrying before repickup, force a drop first
    if State.IsCarrying then
        Helpers.log("Warning: Still carrying before Step 4 repickup. Forcing drop...", "WARN")
        Engine.dropEggSync(1.5)
        task.wait(0.30)
    end
    State.IsCarrying = false

    UI.setStatus(string.format("Re-picking up %s egg in Forest...", State.TargetBiome), Config.Theme.Cyan)
    Helpers.log(string.format("Re-picking up target egg (%s) in Forest for SafeZone...", tostring(targetEggUid)), "SAFEZONE")

    local dropPos = RootPart and RootPart.Position or forestPos
    local attempts = 0
    local maxAttempts = 30

    while attempts < maxAttempts and (not State.TargetEggRepicked or not State.IsCarrying) do
        attempts = attempts + 1
        Helpers.repickupTargetEgg(targetEggUid, dropPos)

        if State.TargetEggRepicked and State.IsCarrying then
            break
        end

        task.wait(0.20)
    end

    -- Strict Guard: MUST be both TargetEggRepicked and IsCarrying to deliver!
    if not State.TargetEggRepicked or not State.IsCarrying then
        UI.setStatus(string.format("⚠️ Failed to re-pick %s egg. Retrying...", State.TargetBiome), Config.Theme.Yellow)
        Helpers.log(string.format("Re-pickup timeout for target egg %s. Cannot deliver to SafeZone.", tostring(targetEggUid)), "WARN")
        State.CurrentPhase = Phases.IDLE
        State.IsActive = false
        return
    end

    -- Return to SafeZone
    local safePos = State.SafeZoneLocation or Vector3.new(542.9, 71.4, -318.7)
    if RootPart and RootPart.Parent then
        local startP = RootPart.Position
        local steps = 8
        for s = 1, steps do
            local alpha = s / steps
            RootPart.CFrame = CFrame.new(startP:Lerp(safePos, alpha))
            task.wait(0.03)
        end
        RootPart.CFrame = CFrame.new(safePos)
        RootPart.AssemblyLinearVelocity = Vector3.zero
        RootPart.AssemblyAngularVelocity = Vector3.zero
    end

    State.Deliveries = State.Deliveries + 1
    UI.setDeliveries(State.Deliveries)
    UI.setStatus(string.format("✓ Returned to SafeZone with %s egg! Ready for next Forest egg.", State.TargetBiome), Config.Theme.Green)
    Helpers.log(string.format("DELIVERED: %s egg (%s) to SafeZone (Total: %d)", State.TargetBiome, tostring(targetEggUid), State.Deliveries), "SUCCESS")

    State.CurrentPhase = Phases.IDLE
    State.IsActive = false
end

-- Direct manual test execution hooks
Engine.executeDrop = function(eggUid)
    local myPos = RootPart and RootPart.Position or Vector3.zero
    local distToForest = (myPos - State.ForestLocation).Magnitude
    if distToForest <= 250.0 then
        Engine.handleForestPickup(eggUid or State.CurrentEggUid or "TestEggUid")
    else
        Engine.handleReturnToForest(eggUid or State.CurrentEggUid or "TestEggUid")
    end
end

Engine.returnToNestAndPickup = function()
    if _G.DropperTargetEggPos then
        State.TargetBiomeLocation = _G.DropperTargetEggPos
    end
    if _G.DropperTargetBiome then
        State.TargetBiome = _G.DropperTargetBiome
    end

    local targetEggPos = State.TargetBiomeLocation or Helpers.getBiomeNestPosition(State.TargetBiome)
    if targetEggPos and RootPart and RootPart.Parent then
        RootPart.CFrame = CFrame.new(targetEggPos)
        Helpers.tryPickupNearbyEgg(targetEggPos, Config.NestScanRadius)
    end
end

-- Event Listeners: Passive listener only. Zero unrequested teleports!
Engine.initListeners = function()
    if Remotes.FieldCarry then
        Helpers.addConn(Remotes.FieldCarry.OnClientEvent:Connect(function(args)
            if typeof(args) == "table" then
                if args.IsCarrying == true or (args.Uid and args.IsCarrying ~= false) then
                    State.IsCarrying = true
                    local eggUid = args.Uid or State.CurrentEggUid
                    State.CarriedUid = eggUid

                    -- Step 4 Re-pickup Guard: ONLY accept target biome egg!
                    if State.CurrentPhase == Phases.REPICKUP_TO_SAFEZONE then
                        local isTarget = (eggUid == State.TargetEggUid)
                            or (State.TargetEggUid and string.find(tostring(eggUid), State.TargetEggUid, 1, true))
                            or (State.TargetBiome ~= "Forest" and not string.find(tostring(eggUid), "Forest", 1, true))

                        if isTarget then
                            State.TargetEggRepicked = true
                            Helpers.log(string.format("Re-picked up %s egg (%s) for SafeZone delivery!", State.TargetBiome, tostring(eggUid)), "SAFEZONE")
                        else
                            Helpers.log(string.format("Wrong egg picked up in Forest (%s)! Ejecting to keep target %s...", tostring(eggUid), tostring(State.TargetEggUid)), "WARN")
                            task.spawn(function()
                                Engine.dropEggSpam(Config.DropSpamCount)
                            end)
                            State.IsCarrying = false
                            State.CarriedUid = nil
                            State.TargetEggRepicked = false
                        end
                        return
                    end

                    if not State.IsActive and eggUid then
                        local myPos = RootPart and RootPart.Position or Vector3.zero
                        local distToForest = (myPos - State.ForestLocation).Magnitude

                        -- Step 1: User manually picked up egg in Forest biome!
                        if distToForest <= 250.0 and (State.CurrentPhase == Phases.IDLE or State.CurrentPhase == nil) then
                            Engine.handleForestPickup(eggUid)
                        -- Step 3: Picked up egg on Target Biome Egg!
                        elseif State.CurrentPhase == Phases.PICKUP_BIOME_EGG or distToForest > 250.0 then
                            if eggUid == State.CurrentEggUid or (State.TargetBiome ~= "Forest" and string.find(tostring(eggUid), "Forest", 1, true)) then
                                Helpers.log(string.format("Accidentally re-picked dropped Forest egg (%s)! Ejecting...", tostring(eggUid)), "WARN")
                                task.spawn(function()
                                    Engine.dropEggSpam(Config.DropSpamCount)
                                end)
                                State.IsCarrying = false
                            else
                                Engine.handleReturnToForest(eggUid)
                            end
                        end
                    end
                elseif args.IsCarrying == false then
                    State.IsCarrying = false
                    State.CarriedUid = nil
                end
            end
        end))
    end

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

-- UI Builder: Clean, showing Target Biome Egg, Forest Biome, SafeZone
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
    main.Size = UDim2.new(0, 320, 0, 276)
    main.Position = UDim2.new(0.5, -160, 0.4, -138)
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
    title.Size = UDim2.new(1, -60, 0, 24)
    title.Position = UDim2.new(0, 10, 0, 4)
    title.BackgroundTransparency = 1
    title.Text = "⚡ Biome Egg Swapper"
    title.TextColor3 = Config.Theme.Cyan
    title.TextSize = 13
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = main

    -- Close Button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 22, 0, 20)
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
    toggleBtn.Size = UDim2.new(0, 24, 0, 20)
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
            UI.setStatus("Swapper Enabled", Config.Theme.Green)
        else
            toggleBtn.Text = "OFF"
            toggleBtn.TextColor3 = Config.Theme.Red
            toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
            UI.setStatus("Swapper Disabled", Config.Theme.Red)
        end
    end))

    -- 1. Target Biome Selector Row (Replaces Pen)
    local biomeRow = Instance.new("Frame")
    biomeRow.Size = UDim2.new(1, -20, 0, 32)
    biomeRow.Position = UDim2.new(0, 10, 0, 30)
    biomeRow.BackgroundColor3 = Config.Theme.Card
    biomeRow.BorderSizePixel = 0
    biomeRow.Parent = main
    Instance.new("UICorner", biomeRow).CornerRadius = UDim.new(0, 6)

    local prevBiomeBtn = Instance.new("TextButton")
    prevBiomeBtn.Size = UDim2.new(0, 28, 0, 22)
    prevBiomeBtn.Position = UDim2.new(0, 4, 0.5, -11)
    prevBiomeBtn.BackgroundColor3 = Color3.fromRGB(40, 48, 68)
    prevBiomeBtn.Text = "◀"
    prevBiomeBtn.TextColor3 = Config.Theme.Cyan
    prevBiomeBtn.TextSize = 10
    prevBiomeBtn.Font = Enum.Font.GothamBold
    prevBiomeBtn.Parent = biomeRow
    Instance.new("UICorner", prevBiomeBtn).CornerRadius = UDim.new(0, 4)

    local nextBiomeBtn = Instance.new("TextButton")
    nextBiomeBtn.Size = UDim2.new(0, 28, 0, 22)
    nextBiomeBtn.Position = UDim2.new(1, -78, 0.5, -11)
    nextBiomeBtn.BackgroundColor3 = Color3.fromRGB(40, 48, 68)
    nextBiomeBtn.Text = "▶"
    nextBiomeBtn.TextColor3 = Config.Theme.Cyan
    nextBiomeBtn.TextSize = 10
    nextBiomeBtn.Font = Enum.Font.GothamBold
    nextBiomeBtn.Parent = biomeRow
    Instance.new("UICorner", nextBiomeBtn).CornerRadius = UDim.new(0, 4)

    local biomeLabel = Instance.new("TextLabel")
    biomeLabel.Size = UDim2.new(1, -120, 1, 0)
    biomeLabel.Position = UDim2.new(0, 36, 0, 0)
    biomeLabel.BackgroundTransparency = 1
    biomeLabel.Text = State.TargetBiome
    biomeLabel.TextColor3 = Config.Theme.Cyan
    biomeLabel.TextSize = 11
    biomeLabel.Font = Enum.Font.GothamBold
    biomeLabel.Parent = biomeRow
    UI.Elements.BiomeLabel = biomeLabel

    local tpNestBtn = Instance.new("TextButton")
    tpNestBtn.Size = UDim2.new(0, 44, 0, 22)
    tpNestBtn.Position = UDim2.new(1, -48, 0.5, -11)
    tpNestBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 80)
    tpNestBtn.Text = "✈ TP"
    tpNestBtn.TextColor3 = Color3.new(1, 1, 1)
    tpNestBtn.TextSize = 10
    tpNestBtn.Font = Enum.Font.GothamBold
    tpNestBtn.Parent = biomeRow
    Instance.new("UICorner", tpNestBtn).CornerRadius = UDim.new(0, 4)

    -- 2. Target Biome Egg Location Card
    local targetCard = Instance.new("Frame")
    targetCard.Size = UDim2.new(1, -20, 0, 34)
    targetCard.Position = UDim2.new(0, 10, 0, 68)
    targetCard.BackgroundColor3 = Config.Theme.Card
    targetCard.BorderSizePixel = 0
    targetCard.Parent = main
    Instance.new("UICorner", targetCard).CornerRadius = UDim.new(0, 6)

    local targetLabel = Instance.new("TextLabel")
    targetLabel.Size = UDim2.new(1, -95, 1, 0)
    targetLabel.Position = UDim2.new(0, 8, 0, 0)
    targetLabel.BackgroundTransparency = 1
    targetLabel.Text = string.format("Target Egg: (%.1f, %.1f, %.1f)", State.TargetBiomeLocation.X, State.TargetBiomeLocation.Y, State.TargetBiomeLocation.Z)
    targetLabel.TextColor3 = Config.Theme.Cyan
    targetLabel.TextSize = 10
    targetLabel.Font = Enum.Font.Gotham
    targetLabel.TextXAlignment = Enum.TextXAlignment.Left
    targetLabel.Parent = targetCard
    UI.Elements.TargetLabel = targetLabel

    local setTargetBtn = Instance.new("TextButton")
    setTargetBtn.Size = UDim2.new(0, 80, 0, 22)
    setTargetBtn.Position = UDim2.new(1, -85, 0.5, -11)
    setTargetBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 180)
    setTargetBtn.Text = "📍 Set Target"
    setTargetBtn.TextColor3 = Color3.new(1, 1, 1)
    setTargetBtn.TextSize = 10
    setTargetBtn.Font = Enum.Font.GothamBold
    setTargetBtn.Parent = targetCard
    Instance.new("UICorner", setTargetBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(setTargetBtn.MouseButton1Click:Connect(function()
        if RootPart and RootPart.Parent then
            State.TargetBiomeLocation = RootPart.Position
            State.StartLocation = RootPart.Position
            targetLabel.Text = string.format("Target Egg: (%.1f, %.1f, %.1f)", State.TargetBiomeLocation.X, State.TargetBiomeLocation.Y, State.TargetBiomeLocation.Z)
            UI.setStatus("Target Biome Egg location updated!", Config.Theme.Green)
            Helpers.log(string.format("Target Biome Egg set to V3(%.1f, %.1f, %.1f)", State.TargetBiomeLocation.X, State.TargetBiomeLocation.Y, State.TargetBiomeLocation.Z), "LOCATION")
        end
    end))

    local function updateBiomeSelection(idx)
        State.SelectedBiomeIndex = math.clamp(idx, 1, #Config.Biomes)
        State.TargetBiome = Config.Biomes[State.SelectedBiomeIndex]
        biomeLabel.Text = State.TargetBiome
        local newPos = Helpers.getBiomeNestPosition(State.TargetBiome)
        if newPos then
            State.TargetBiomeLocation = newPos
            State.StartLocation = newPos
            targetLabel.Text = string.format("Target Egg: (%.1f, %.1f, %.1f)", newPos.X, newPos.Y, newPos.Z)
        end
        UI.setStatus("Target Biome: " .. State.TargetBiome, Config.Theme.Cyan)
        Helpers.log("Target biome switched to: " .. State.TargetBiome, "BIOME")
    end

    Helpers.addConn(prevBiomeBtn.MouseButton1Click:Connect(function()
        local idx = State.SelectedBiomeIndex - 1
        if idx < 1 then idx = #Config.Biomes end
        updateBiomeSelection(idx)
    end))

    Helpers.addConn(nextBiomeBtn.MouseButton1Click:Connect(function()
        local idx = State.SelectedBiomeIndex + 1
        if idx > #Config.Biomes then idx = 1 end
        updateBiomeSelection(idx)
    end))

    Helpers.addConn(tpNestBtn.MouseButton1Click:Connect(function()
        local pos = State.TargetBiomeLocation or Helpers.getBiomeNestPosition(State.TargetBiome)
        if pos and RootPart and RootPart.Parent then
            RootPart.CFrame = CFrame.new(pos)
            RootPart.AssemblyLinearVelocity = Vector3.zero
            UI.setStatus("Teleported to " .. State.TargetBiome .. " Egg", Config.Theme.Green)
        else
            UI.setStatus("Nest position not found for " .. State.TargetBiome, Config.Theme.Yellow)
        end
    end))

    -- 3. Forest Location Card (Where initial egg is picked & where biome egg is dropped)
    local forestCard = Instance.new("Frame")
    forestCard.Size = UDim2.new(1, -20, 0, 34)
    forestCard.Position = UDim2.new(0, 10, 0, 106)
    forestCard.BackgroundColor3 = Config.Theme.Card
    forestCard.BorderSizePixel = 0
    forestCard.Parent = main
    Instance.new("UICorner", forestCard).CornerRadius = UDim.new(0, 6)

    local forestLabel = Instance.new("TextLabel")
    forestLabel.Size = UDim2.new(1, -95, 1, 0)
    forestLabel.Position = UDim2.new(0, 8, 0, 0)
    forestLabel.BackgroundTransparency = 1
    forestLabel.Text = string.format("Forest: (%.1f, %.1f, %.1f)", State.ForestLocation.X, State.ForestLocation.Y, State.ForestLocation.Z)
    forestLabel.TextColor3 = Config.Theme.TextPrimary
    forestLabel.TextSize = 10
    forestLabel.Font = Enum.Font.Gotham
    forestLabel.TextXAlignment = Enum.TextXAlignment.Left
    forestLabel.Parent = forestCard
    UI.Elements.ForestLabel = forestLabel

    local setForestBtn = Instance.new("TextButton")
    setForestBtn.Size = UDim2.new(0, 80, 0, 22)
    setForestBtn.Position = UDim2.new(1, -85, 0.5, -11)
    setForestBtn.BackgroundColor3 = Color3.fromRGB(35, 110, 80)
    setForestBtn.Text = "📍 Set Forest"
    setForestBtn.TextColor3 = Color3.new(1, 1, 1)
    setForestBtn.TextSize = 10
    setForestBtn.Font = Enum.Font.GothamBold
    setForestBtn.Parent = forestCard
    Instance.new("UICorner", setForestBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(setForestBtn.MouseButton1Click:Connect(function()
        if RootPart and RootPart.Parent then
            State.ForestLocation = RootPart.Position
            State.ForestDropLocation = RootPart.Position
            State.SavedLocation = RootPart.Position
            forestLabel.Text = string.format("Forest: (%.1f, %.1f, %.1f)", State.ForestLocation.X, State.ForestLocation.Y, State.ForestLocation.Z)
            UI.setStatus("Forest location updated!", Config.Theme.Green)
            Helpers.log(string.format("Forest location set to V3(%.1f, %.1f, %.1f)", State.ForestLocation.X, State.ForestLocation.Y, State.ForestLocation.Z), "LOCATION")
        end
    end))

    -- 4. SafeZone Location Card (Where we return after repick up)
    local safeCard = Instance.new("Frame")
    safeCard.Size = UDim2.new(1, -20, 0, 34)
    safeCard.Position = UDim2.new(0, 10, 0, 142)
    safeCard.BackgroundColor3 = Config.Theme.Card
    safeCard.BorderSizePixel = 0
    safeCard.Parent = main
    Instance.new("UICorner", safeCard).CornerRadius = UDim.new(0, 6)

    local safeLabel = Instance.new("TextLabel")
    safeLabel.Size = UDim2.new(1, -95, 1, 0)
    safeLabel.Position = UDim2.new(0, 8, 0, 0)
    safeLabel.BackgroundTransparency = 1
    safeLabel.Text = string.format("SafeZone: (%.1f, %.1f, %.1f)", State.SafeZoneLocation.X, State.SafeZoneLocation.Y, State.SafeZoneLocation.Z)
    safeLabel.TextColor3 = Config.Theme.Green
    safeLabel.TextSize = 10
    safeLabel.Font = Enum.Font.Gotham
    safeLabel.TextXAlignment = Enum.TextXAlignment.Left
    safeLabel.Parent = safeCard
    UI.Elements.SafeLabel = safeLabel

    local setSafeBtn = Instance.new("TextButton")
    setSafeBtn.Size = UDim2.new(0, 80, 0, 22)
    setSafeBtn.Position = UDim2.new(1, -85, 0.5, -11)
    setSafeBtn.BackgroundColor3 = Color3.fromRGB(35, 95, 65)
    setSafeBtn.Text = "📍 Set Safe"
    setSafeBtn.TextColor3 = Color3.new(1, 1, 1)
    setSafeBtn.TextSize = 10
    setSafeBtn.Font = Enum.Font.GothamBold
    setSafeBtn.Parent = safeCard
    Instance.new("UICorner", setSafeBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(setSafeBtn.MouseButton1Click:Connect(function()
        if RootPart and RootPart.Parent then
            State.SafeZoneLocation = RootPart.Position
            safeLabel.Text = string.format("SafeZone: (%.1f, %.1f, %.1f)", State.SafeZoneLocation.X, State.SafeZoneLocation.Y, State.SafeZoneLocation.Z)
            UI.setStatus("SafeZone location updated!", Config.Theme.Green)
            Helpers.log(string.format("SafeZone set to V3(%.1f, %.1f, %.1f)", State.SafeZoneLocation.X, State.SafeZoneLocation.Y, State.SafeZoneLocation.Z), "LOCATION")
        end
    end))

    -- Info: Status Banner
    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -20, 0, 30)
    status.Position = UDim2.new(0, 10, 0, 180)
    status.BackgroundColor3 = Config.Theme.Card
    status.Text = "Status: Ready · Pick up egg in Forest"
    status.TextColor3 = Config.Theme.Green
    status.TextSize = 11
    status.Font = Enum.Font.Gotham
    status.Parent = main
    Instance.new("UICorner", status).CornerRadius = UDim.new(0, 6)
    UI.Elements.Status = status

    -- Info: Stats Row
    local statsLabel = Instance.new("TextLabel")
    statsLabel.Size = UDim2.new(1, -20, 0, 18)
    statsLabel.Position = UDim2.new(0, 10, 0, 214)
    statsLabel.BackgroundTransparency = 1
    statsLabel.Text = "Deliveries: 0 | Target: " .. State.TargetBiome
    statsLabel.TextColor3 = Config.Theme.TextDim
    statsLabel.TextSize = 10
    statsLabel.Font = Enum.Font.Gotham
    statsLabel.Parent = main
    UI.Elements.StatsLabel = statsLabel

    -- Bottom Buttons: Test Drop + Copy Log
    local testBtn = Instance.new("TextButton")
    testBtn.Size = UDim2.new(0, 145, 0, 26)
    testBtn.Position = UDim2.new(0, 10, 0, 238)
    testBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 65)
    testBtn.Text = "⚡ Test Drop"
    testBtn.TextColor3 = Config.Theme.Cyan
    testBtn.TextSize = 10
    testBtn.Font = Enum.Font.GothamBold
    testBtn.Parent = main
    Instance.new("UICorner", testBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(testBtn.MouseButton1Click:Connect(function()
        Engine.executeDrop(State.CurrentEggUid or "TestEggUid")
    end))

    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(0, 145, 0, 26)
    copyBtn.Position = UDim2.new(1, -155, 0, 238)
    copyBtn.BackgroundColor3 = Color3.fromRGB(35, 55, 45)
    copyBtn.Text = "📋 Copy Log"
    copyBtn.TextColor3 = Config.Theme.Green
    copyBtn.TextSize = 10
    copyBtn.Font = Enum.Font.GothamBold
    copyBtn.Parent = main
    Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 4)
    Helpers.addConn(copyBtn.MouseButton1Click:Connect(function()
        local ok, count = Helpers.copyLogs()
        if ok then
            copyBtn.Text = "✓ Copied (" .. count .. ")"
            task.delay(1.5, function()
                if copyBtn and copyBtn.Parent then
                    copyBtn.Text = "📋 Copy Log"
                end
            end)
        else
            copyBtn.Text = "⚠️ Failed"
            task.delay(1.5, function()
                if copyBtn and copyBtn.Parent then
                    copyBtn.Text = "📋 Copy Log"
                end
            end)
        end
    end))

    UI.Elements.ScreenGui = screenGui
end

UI.setStatus = function(text, color)
    if UI.Elements.Status and UI.Elements.Status.Parent then
        UI.Elements.Status.Text = tostring(text)
        if color then
            UI.Elements.Status.TextColor3 = color
        end
    end
end

UI.setDeliveries = function(count)
    if UI.Elements.StatsLabel and UI.Elements.StatsLabel.Parent then
        UI.Elements.StatsLabel.Text = string.format("Deliveries: %d | Target: %s", count, State.TargetBiome)
    end
end

-- Cleanup Handler
local function fullCleanup()
    Helpers.disconnectAll()
    if UI.Elements.ScreenGui and UI.Elements.ScreenGui.Parent then
        pcall(function() UI.Elements.ScreenGui:Destroy() end)
    end
    _G.Dropper_Engine = nil
    _G.Dropper_State = nil
    print("[MultiBiomeDropper] Cleaned up cleanly.")
end

_G.ForestDropper_Cleanup = fullCleanup
_G.Dropper_Engine = Engine
_G.Dropper_State = State

-- Startup: Passive listener only. Zero random teleports!
UI.init()
Engine.initListeners()
Helpers.log("Multi-Biome Dropper loaded. Waiting for manual Forest pickup. Target: " .. tostring(State.TargetBiome), "SYSTEM")
