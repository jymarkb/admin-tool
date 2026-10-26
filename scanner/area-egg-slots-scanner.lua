--[[
    ADVANCED EGG SLOTS & INTERACTIVE TEST CASE SCANNER
    Purpose:
      1. Extracts full egg spawn details from `workspace.AreaEggSlotsClient`:
         - Egg UID & Model Name
         - Species extracted from PreparedSourceName, Model parts, or name
         - Biome / Area resolved from (X, Y, Z) coordinates & name patterns
         - Precise CFrame / Vector3 coordinates
      2. Classifies Spawn Events:
         - 🌙 [NIGHT RESET]: Full 5-minute (300s) mass wave (50-65 eggs refreshed)
         - 🚨 [ADMIN ABUSE / SPECIAL]: Mid-cycle sudden spawns (<270s) & rare alerts
      3. Verifies and Logs All Interactive Test Cases:
         - 🟢 [I PICKED UP]: Local player picks up an egg
         - 🏆 [I DELIVERED]: Local player delivers egg to safezone / claim point
         - 📦 [I DROPPED]: Local player drops an egg onto the ground
         - 🚨 [SOMEONE STOLE IT]: Another player snatches our egg (Theft detection)
         - 🤾 [RIVAL DROPPED]: Another player drops an egg on the ground
         - 💨 [DESPAWN / EXPIRED]: Egg cycle expiry or removal
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer or Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")
local MyUserIdStr = tostring(LocalPlayer.UserId)

if _G.AdvancedEggScanner_Cleanup then
    pcall(_G.AdvancedEggScanner_Cleanup)
end

local function getGuiParent()
    if typeof(gethui) == "function" then
        local ok, parent = pcall(gethui)
        if ok and parent then return parent end
    end
    return PlayerGui or CoreGui
end

local function getNetRemote(name)
    local pkg = ReplicatedStorage:FindFirstChild("Packages")
    local net = pkg and pkg:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    return ReplicatedStorage:FindFirstChild(name, true)
end

local Remotes = {
    FieldEggShifted       = getNetRemote("RE/EggWorld/FieldEggShifted"),
    FieldEggGone          = getNetRemote("RE/EggWorld/FieldEggGone"),
    FieldEggBatchShifted  = getNetRemote("RE/EggWorld/FieldEggBatchShifted"),
    FieldEggRaritiesShown = getNetRemote("RE/EggWorld/FieldEggRaritiesShown"),
    AlertsRaise           = getNetRemote("RE/Alerts/Raise"),
    BroadcastsRaiseNotice = getNetRemote("RE/Broadcasts/RaiseNotice"),
}

-- ============================================================
-- TAXONOMY & BIOME RESOLUTION ENGINE
-- ============================================================

local SPECIES_CATALOG = {
    ["Chicken"]           = { Biome = "Forest", Rarity = "Common" },
    ["Dog"]               = { Biome = "Forest", Rarity = "Common" },
    ["Bird"]              = { Biome = "Forest", Rarity = "Uncommon" },
    ["Burrowing Owl"]     = { Biome = "Forest", Rarity = "Rare" },
    ["Owl"]               = { Biome = "Forest", Rarity = "Rare" },
    ["Frog"]              = { Biome = "Lake", Rarity = "Common" },
    ["Duck"]              = { Biome = "Lake", Rarity = "Common" },
    ["Otter"]             = { Biome = "Lake", Rarity = "Rare" },
    ["Coyote"]            = { Biome = "Desert", Rarity = "Common" },
    ["Rattlesnake"]       = { Biome = "Desert", Rarity = "Uncommon" },
    ["Camel"]             = { Biome = "Desert", Rarity = "Rare" },
    ["Monkey"]            = { Biome = "Jungle", Rarity = "Common" },
    ["Parrot"]            = { Biome = "Jungle", Rarity = "Uncommon" },
    ["Cheetah"]           = { Biome = "Jungle", Rarity = "Rare" },
    ["Polar Bear"]        = { Biome = "Snow", Rarity = "Common" },
    ["Seal"]              = { Biome = "Snow", Rarity = "Uncommon" },
    ["Penguin"]           = { Biome = "Snow", Rarity = "Rare" },
    ["Magma Golem"]       = { Biome = "Volcano", Rarity = "Rare" },
    ["Volcano Turtle"]    = { Biome = "Volcano", Rarity = "Legendary" },
    ["Pufferfish"]        = { Biome = "Abyss Ocean", Rarity = "Rare" },
    ["Anglerfish"]        = { Biome = "Abyss Ocean", Rarity = "Legendary" },
    ["Shark"]             = { Biome = "Abyss Ocean", Rarity = "Mythic" },
    ["Raptor"]            = { Biome = "Prehistoric", Rarity = "Rare" },
    ["T-Rex"]             = { Biome = "Prehistoric", Rarity = "Mythic" },
    ["Star Cat"]          = { Biome = "Cosmic", Rarity = "Legendary" },
    ["Supernova Dragon"]  = { Biome = "Cosmic", Rarity = "Divine" },
    ["Crane"]             = { Biome = "Cherry Blossom", Rarity = "Rare" },
    ["Kitsune"]           = { Biome = "Cherry Blossom", Rarity = "Divine" },
    ["Kaiju Spider"]      = { Biome = "Titan Temple", Rarity = "Legendary" },
    ["Titan Golem"]       = { Biome = "Titan Temple", Rarity = "Divine" },
    ["Prism Gecko"]       = { Biome = "Enchanted Forest", Rarity = "Legendary" },
    ["Petal Beetle"]      = { Biome = "Enchanted Forest", Rarity = "Mythic" },
    ["Enchanted Bluejay"] = { Biome = "Enchanted Forest", Rarity = "Mythic" },
    ["Astral Jackalope"]  = { Biome = "Enchanted Forest", Rarity = "Cosmic" },
    ["Halloween Egg"]     = { Biome = "Halloween Dimension", Rarity = "Secret" },
    ["Voidseer Pumpkin"]  = { Biome = "Halloween Dimension", Rarity = "Divine" },
    ["Hexed Pumpkin"]     = { Biome = "Halloween Dimension", Rarity = "Cosmic" },
}

local function resolveBiomeFromPosition(pos)
    if not pos then return "Unknown" end
    local x, z = pos.X, pos.Z

    -- Halloween Dimension check
    if x < -5000 and z < -6500 then
        return "Halloween Dimension"
    end

    -- Overworld X-coordinate bands
    if x >= 500 and x < 680 then return "Forest"
    elseif x >= 680 and x < 850 then return "Lake"
    elseif x >= 850 and x < 1050 then return "Desert"
    elseif x >= 1050 and x < 1300 then return "Jungle"
    elseif x >= 1300 and x < 1650 then return "Snow"
    elseif x >= 1650 and x < 2050 then return "Volcano"
    elseif x >= 2050 and x < 2500 then return "Abyss Ocean"
    elseif x >= 2500 and x < 3100 then return "Prehistoric"
    elseif x >= 3100 and x < 3700 then return "Cosmic"
    elseif x >= 3700 and x < 4400 then return "Cherry Blossom"
    elseif x >= 4400 and x < 5200 then return "Titan Temple"
    elseif x >= 5200 and x < 6100 then return "Light & Dark"
    elseif x >= 6100 and x < 7500 then return "Enchanted Forest"
    end
    return "Overworld"
end

local function extractSpeciesFromModel(model)
    if not model then return "Unknown Egg", "Unknown" end

    -- 1. Check PreparedSourceName attribute
    local src = model:GetAttribute("PreparedSourceName")
    if type(src) == "string" and src ~= "" then
        local baseName = src:match("([^%.]+)$") or src
        local spaced = baseName:gsub("(%l)(%u)", "%1 %2")
        if SPECIES_CATALOG[spaced] then
            return spaced, SPECIES_CATALOG[spaced].Rarity
        elseif SPECIES_CATALOG[baseName] then
            return baseName, SPECIES_CATALOG[baseName].Rarity
        end
        return spaced, "Discovered"
    end

    -- 2. Check Name patterns
    local name = model.Name
    if name:find("Forest:Slot") then
        return "Forest Egg", "Common"
    end

    -- 3. Check direct attributes
    local attrSpecies = model:GetAttribute("DisplayName") or model:GetAttribute("Species")
    local attrRarity = model:GetAttribute("Rarity") or model:GetAttribute("RarityId")
    if attrSpecies then
        return tostring(attrSpecies), tostring(attrRarity or "Unknown")
    end

    -- 4. Check sub-parts
    for _, ch in ipairs(model:GetChildren()) do
        if SPECIES_CATALOG[ch.Name] then
            return ch.Name, SPECIES_CATALOG[ch.Name].Rarity
        end
    end

    return "Field Egg", "Unknown"
end

local function getInstancePos(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then
        return inst.Position
    elseif inst:IsA("Model") then
        local ok, cf = pcall(function() return inst:GetPivot() end)
        if ok and cf then return cf.Position end
        if inst.PrimaryPart then return inst.PrimaryPart.Position end
    elseif inst:IsA("Attachment") then
        return inst.WorldPosition
    end
    return nil
end

local function formatVector3(v)
    if typeof(v) == "Vector3" then
        return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
    elseif typeof(v) == "CFrame" then
        local p = v.Position
        return string.format("(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z)
    end
    return "N/A"
end

-- ============================================================
-- SCANNER STATE & LOGGING
-- ============================================================

local state = {
    alive = true,
    connections = {},
    lastNightResetTime = nil,
    totalNightResets = 0,
    totalAdminEvents = 0,
    totalDeliveries = 0,
    totalThefts = 0,
    totalDrops = 0,
    totalPickups = 0,
    myCarriedEgg = nil,      -- { Uid = ..., Species = ..., Biome = ..., PickedAt = ... }
    trackedEggs = {},        -- Uid -> { Name, Species, Biome, Pos, State, CarrierUserId }
}

local logLines = {}
local MAX_LOG_LINES = 350

local function appendLog(msg)
    local timestamp = os.date("%H:%M:%S")
    local line = string.format("[%s] %s", timestamp, tostring(msg))
    table.insert(logLines, line)
    if #logLines > MAX_LOG_LINES then
        table.remove(logLines, 1)
    end
    print("[AdvancedEggScanner] " .. tostring(msg))
    if state.updateLogUI then
        state.updateLogUI()
    end
end

-- ============================================================
-- 1. FULL AUDIT: WORKSPACE.AREAEGGSLOTSCLIENT
-- ============================================================

local function auditAreaEggSlots(isRescan)
    local prefix = isRescan and ">>> RESCANNING" or ">>> INITIAL SCAN:"
    appendLog("==================================================")
    appendLog(string.format("%s workspace.AreaEggSlotsClient...", prefix))

    local container = Workspace:FindFirstChild("AreaEggSlotsClient")
    if not container then
        appendLog("[-] 'AreaEggSlotsClient' folder not found in Workspace!")
        appendLog("==================================================")
        return
    end

    local children = container:GetChildren()
    appendLog(string.format("[+] Found AreaEggSlotsClient with %d active slots", #children))

    local biomeCounts = {}
    local samples = {}

    for i, child in ipairs(children) do
        local uid = child.Name
        local pos = getInstancePos(child)
        local biome = resolveBiomeFromPosition(pos)
        local species, rarity = extractSpeciesFromModel(child)

        biomeCounts[biome] = (biomeCounts[biome] or 0) + 1
        state.trackedEggs[uid] = {
            Uid = uid,
            Name = child.Name,
            Species = species,
            Rarity = rarity,
            Biome = biome,
            Pos = pos,
            State = "Slot",
            CarrierUserId = nil,
        }

        if i <= 6 or (rarity ~= "Common" and rarity ~= "Unknown" and #samples < 10) then
            table.insert(samples, string.format("  [%d] UID: %s... | %s [%s] | Biome: %s | Pos: %s",
                i, uid:sub(1, 8), species, rarity, biome, pos and formatVector3(pos) or "nil"))
        end
    end

    local biomeList = {}
    for b, cnt in pairs(biomeCounts) do
        table.insert(biomeList, string.format("%s:%d", b, cnt))
    end
    table.sort(biomeList)
    appendLog("    Biomes: " .. table.concat(biomeList, " | "))

    appendLog("--- Sample Egg Details ---")
    for _, s in ipairs(samples) do
        appendLog(s)
    end
    appendLog("==================================================")
end

-- ============================================================
-- 2. WAVE & SPAWN DETECTOR (NIGHT RESET VS ADMIN ABUSE)
-- ============================================================

local waveAccumulator = 0
local waveFlushThread = nil

local function flushWave()
    if not state.alive then return end
    if waveAccumulator >= 20 then
        local now = os.clock()
        local timeSinceReset = state.lastNightResetTime and (now - state.lastNightResetTime) or nil

        if timeSinceReset == nil or timeSinceReset >= 270 then
            state.totalNightResets = state.totalNightResets + 1
            state.lastNightResetTime = now
            local cycleInfo = timeSinceReset and string.format(" (after %.1fs / 5m cycle)", timeSinceReset) or " (initial / first detected)"
            appendLog(string.format("🌙 [SPAWN: NIGHT RESET #%d] Mass wave of %d eggs refreshed across all 13 biomes%s!",
                state.totalNightResets, waveAccumulator, cycleInfo))
        else
            state.totalAdminEvents = state.totalAdminEvents + 1
            appendLog(string.format("🚨 [SPAWN: ADMIN ABUSE EVENT #%d] Sudden mid-cycle wave of %d egg(s) spawned (%.1fs into cycle)!",
                state.totalAdminEvents, waveAccumulator, timeSinceReset))
        end
    end
    waveAccumulator = 0
    waveFlushThread = nil
end

local function recordEggSpawned(child)
    waveAccumulator = waveAccumulator + 1
    if waveFlushThread then
        pcall(function() task.cancel(waveFlushThread) end)
    end
    waveFlushThread = task.delay(1.2, flushWave)

    local uid = child.Name
    local pos = getInstancePos(child)
    local biome = resolveBiomeFromPosition(pos)
    local species, rarity = extractSpeciesFromModel(child)

    state.trackedEggs[uid] = {
        Uid = uid,
        Name = child.Name,
        Species = species,
        Rarity = rarity,
        Biome = biome,
        Pos = pos,
        State = "Slot",
        CarrierUserId = nil,
    }

    if rarity == "Secret" or rarity == "Divine" or rarity == "Cosmic" or rarity == "Mythic" then
        appendLog(string.format("✨ [HIGH-TIER EGG SPAWNED] %s [%s] in %s at %s (UID: %s...)",
            species, rarity, biome, pos and formatVector3(pos) or "nil", uid:sub(1, 8)))
    end
end

-- ============================================================
-- 3. INTERACTIVE TEST CASE HANDLERS
-- ============================================================

local function handleEggStateShift(uid, newState, carrierId, pos, meta)
    local egg = state.trackedEggs[uid] or {
        Uid = uid,
        Species = meta and meta.DisplayName or "Egg",
        Rarity = meta and meta.RarityId or "Unknown",
        Biome = meta and meta.AreaId or "Unknown",
        Pos = pos,
    }
    local oldState = egg.State
    local oldCarrier = egg.CarrierUserId
    egg.State = newState
    egg.CarrierUserId = carrierId
    if pos then egg.Pos = pos end
    state.trackedEggs[uid] = egg

    local isMe = (carrierId and tostring(carrierId) == MyUserIdStr)
    local wasMe = (oldCarrier and tostring(oldCarrier) == MyUserIdStr)

    -- TEST CASE 1: I PICKED UP THE EGG
    if newState == "Carried" and isMe then
        state.totalPickups = state.totalPickups + 1
        state.myCarriedEgg = {
            Uid = uid,
            Species = egg.Species,
            Rarity = egg.Rarity,
            Biome = egg.Biome,
            PickedAt = os.clock(),
            PickupPos = pos or egg.Pos,
        }
        appendLog(string.format("🟢 [TEST CASE: I PICKED UP] Uid=%s... | %s [%s] | From %s at %s",
            uid:sub(1, 8), egg.Species, egg.Rarity, egg.Biome, formatVector3(pos or egg.Pos)))

    -- TEST CASE 2: I DELIVERED THE EGG
    elseif (newState == "Claimed" or newState == "Delivered") and (wasMe or (state.myCarriedEgg and state.myCarriedEgg.Uid == uid)) then
        state.totalDeliveries = state.totalDeliveries + 1
        local heldTime = state.myCarriedEgg and (os.clock() - state.myCarriedEgg.PickedAt) or 0
        appendLog(string.format("🏆 [TEST CASE: I DELIVERED IT!] Uid=%s... | %s [%s] delivered to SafeZone! Trip Time: %.1fs",
            uid:sub(1, 8), egg.Species, egg.Rarity, heldTime))
        state.myCarriedEgg = nil

    -- TEST CASE 3: I DROPPED THE EGG
    elseif newState == "Dropped" and wasMe then
        state.totalDrops = state.totalDrops + 1
        appendLog(string.format("📦 [TEST CASE: I DROPPED IT] Uid=%s... | %s [%s] dropped on ground at %s",
            uid:sub(1, 8), egg.Species, egg.Rarity, formatVector3(pos or egg.Pos)))
        state.myCarriedEgg = nil

    -- TEST CASE 4: SOMEONE STOLE IT / RIVAL CARRIER
    elseif newState == "Carried" and not isMe then
        local rivalName = "User_" .. tostring(carrierId)
        local p = Players:GetPlayerByUserId(tonumber(carrierId) or 0)
        if p then rivalName = p.DisplayName .. " (@" .. p.Name .. ")" end

        if wasMe or (state.myCarriedEgg and state.myCarriedEgg.Uid == uid) then
            state.totalThefts = state.totalThefts + 1
            appendLog(string.format("🚨 [TEST CASE: SOMEONE STOLE IT!] Thief: %s snatched our egg! Uid=%s... (%s [%s])",
                rivalName, uid:sub(1, 8), egg.Species, egg.Rarity))
            state.myCarriedEgg = nil
        else
            appendLog(string.format("👤 [RIVAL CARRIED] %s picked up Uid=%s... (%s [%s] in %s)",
                rivalName, uid:sub(1, 8), egg.Species, egg.Rarity, egg.Biome))
        end

    -- TEST CASE 5: RIVAL DROPPED THE EGG
    elseif newState == "Dropped" and not wasMe then
        appendLog(string.format("🤾 [TEST CASE: RIVAL DROPPED] Uid=%s... (%s [%s]) dropped onto field at %s (Now available for pickup!)",
            uid:sub(1, 8), egg.Species, egg.Rarity, formatVector3(pos or egg.Pos)))

    -- OTHER SHIFTS
    elseif newState == "Claimed" and not wasMe then
        appendLog(string.format("🏁 [RIVAL CLAIMED] Uid=%s... (%s) was claimed by another player.", uid:sub(1, 8), egg.Species))
        state.trackedEggs[uid] = nil
    end
end

-- ============================================================
-- 4. ATTACH LISTENERS (WORKSPACE & REMOTES)
-- ============================================================

local function startListeners()
    -- A. Workspace.AreaEggSlotsClient monitoring
    local container = Workspace:FindFirstChild("AreaEggSlotsClient")
    if container then
        local cAdd = container.ChildAdded:Connect(function(child)
            recordEggSpawned(child)
        end)
        table.insert(state.connections, cAdd)

        local cRem = container.ChildRemoved:Connect(function(child)
            local uid = child.Name
            local egg = state.trackedEggs[uid]
            if egg and egg.State == "Slot" then
                -- Despawn or picked up
                egg.State = "Cleared"
            end
        end)
        table.insert(state.connections, cRem)
    end

    -- B. RemoteEvent: FieldEggShifted
    if Remotes.FieldEggShifted and Remotes.FieldEggShifted:IsA("RemoteEvent") then
        local c = Remotes.FieldEggShifted.OnClientEvent:Connect(function(payload)
            if not state.alive or typeof(payload) ~= "table" then return end
            local uid = tostring(payload.Uid or payload.EggUid or "")
            if uid == "" then return end

            local newState = payload.State or "Shifted"
            local carrier = payload.CarrierUserId
            local cf = payload.BoundsCFrame or payload.Position
            local pos = nil
            if typeof(cf) == "CFrame" then pos = cf.Position
            elseif typeof(cf) == "Vector3" then pos = cf
            end

            handleEggStateShift(uid, newState, carrier, pos, payload)
        end)
        table.insert(state.connections, c)
    end

    -- C. RemoteEvent: FieldEggGone (Despawn)
    if Remotes.FieldEggGone and Remotes.FieldEggGone:IsA("RemoteEvent") then
        local c = Remotes.FieldEggGone.OnClientEvent:Connect(function(payload)
            if not state.alive then return end
            local uid = typeof(payload) == "table" and tostring(payload.Uid or payload.EggUid or "") or tostring(payload or "")
            if uid ~= "" then
                local egg = state.trackedEggs[uid]
                local desc = egg and string.format("%s [%s]", egg.Species, egg.Rarity) or "Egg"
                appendLog(string.format("💨 [TEST CASE: DESPAWN / EXPIRED] Uid=%s... (%s) expired or was removed from field.", uid:sub(1, 8), desc))
                if state.myCarriedEgg and state.myCarriedEgg.Uid == uid then
                    appendLog("⚠️ [DESPAWN WARNING] The egg we were carrying despawned mid-trip!")
                    state.myCarriedEgg = nil
                end
                state.trackedEggs[uid] = nil
            end
        end)
        table.insert(state.connections, c)
    end

    -- D. RemoteEvent: AlertsRaise (Deliveries & Rewards)
    if Remotes.AlertsRaise and Remotes.AlertsRaise:IsA("RemoteEvent") then
        local c = Remotes.AlertsRaise.OnClientEvent:Connect(function(alert)
            if not state.alive or typeof(alert) ~= "table" then return end
            local txt = tostring(alert.Text or "")
            if txt:find("Candy Corn") or txt:find("Delivered") or txt:find("Claimed") then
                appendLog(string.format("💰 [REWARD / DELIVERY TOAST] %s", txt))
            end
        end)
        table.insert(state.connections, c)
    end

    -- E. RemoteEvent: BroadcastsRaiseNotice & RaritiesShown (Admin Abuse Announcements)
    if Remotes.BroadcastsRaiseNotice and Remotes.BroadcastsRaiseNotice:IsA("RemoteEvent") then
        local c = Remotes.BroadcastsRaiseNotice.OnClientEvent:Connect(function(msg)
            if not state.alive then return end
            appendLog(string.format("📢 [BROADCAST NOTICE] %s", tostring(msg and msg.Text or msg)))
        end)
        table.insert(state.connections, c)
    end

    if Remotes.FieldEggRaritiesShown and Remotes.FieldEggRaritiesShown:IsA("RemoteEvent") then
        local c = Remotes.FieldEggRaritiesShown.OnClientEvent:Connect(function(payload)
            if not state.alive or typeof(payload) ~= "table" then return end
            if typeof(payload.RareSpawns) == "table" then
                local rares = {}
                for _, r in pairs(payload.RareSpawns) do
                    if typeof(r) == "table" and r.EggUid and r.RarityId then
                        table.insert(rares, string.format("%s: %s", tostring(r.RarityId), tostring(r.EggUid):sub(1, 8)))
                    end
                end
                if #rares > 0 then
                    appendLog(string.format("✨ [ADMIN / RARE SPAWN ANNOUNCEMENT] %s", table.concat(rares, ", ")))
                end
            end
        end)
        table.insert(state.connections, c)
    end
end

-- ============================================================
-- 5. COMPLETE DRILL-DOWN GUI
-- ============================================================

local function buildUI()
    local parent = getGuiParent()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "AdvancedEggScannerGui"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local mainFrame = Instance.new("Frame")
    mainFrame.Name = "MainFrame"
    mainFrame.Size = UDim2.new(0, 620, 0, 520)
    mainFrame.Position = UDim2.new(0.5, -310, 0.5, -260)
    mainFrame.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
    mainFrame.BorderSizePixel = 0
    mainFrame.Parent = screenGui

    Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", mainFrame)
    stroke.Color = Color3.fromRGB(55, 65, 85)
    stroke.Thickness = 1.2

    -- Title Bar
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 38)
    titleBar.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = mainFrame
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, -70, 1, 0)
    titleLabel.Position = UDim2.new(0, 12, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "🔬 Advanced Egg Spawn & Test-Case Engine"
    titleLabel.TextColor3 = Color3.fromRGB(235, 240, 255)
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 13
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = titleBar

    -- Close Button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 28, 0, 28)
    closeBtn.Position = UDim2.new(1, -32, 0, 5)
    closeBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.fromRGB(200, 205, 220)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 13
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

    -- Status Sub-Header
    local subHeader = Instance.new("Frame")
    subHeader.Size = UDim2.new(1, -16, 0, 24)
    subHeader.Position = UDim2.new(0, 8, 0, 42)
    subHeader.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
    subHeader.BorderSizePixel = 0
    subHeader.Parent = mainFrame
    Instance.new("UICorner", subHeader).CornerRadius = UDim.new(0, 4)

    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, -10, 1, 0)
    statusLabel.Position = UDim2.new(0, 6, 0, 0)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "Resets: 0 | Admin Waves: 0 | Deliveries: 0 | Thefts: 0 | Drops: 0 | Pickups: 0"
    statusLabel.TextColor3 = Color3.fromRGB(150, 200, 255)
    statusLabel.Font = Enum.Font.GothamMedium
    statusLabel.TextSize = 11
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Parent = subHeader

    -- Scroll Log
    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -16, 1, -118)
    scroll.Position = UDim2.new(0, 8, 0, 70)
    scroll.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 5
    scroll.ScrollBarImageColor3 = Color3.fromRGB(65, 75, 100)
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = mainFrame
    Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 6)

    local logText = Instance.new("TextLabel")
    logText.Size = UDim2.new(1, -12, 1, 0)
    logText.Position = UDim2.new(0, 6, 0, 4)
    logText.BackgroundTransparency = 1
    logText.Text = ""
    logText.TextColor3 = Color3.fromRGB(180, 220, 255)
    logText.Font = Enum.Font.Code
    logText.TextSize = 11
    logText.TextXAlignment = Enum.TextXAlignment.Left
    logText.TextYAlignment = Enum.TextYAlignment.Top
    logText.TextWrapped = true
    logText.Parent = scroll

    state.updateLogUI = function()
        statusLabel.Text = string.format("Resets: %d | Admin Waves: %d | Deliveries: %d | Thefts: %d | Drops: %d | Pickups: %d",
            state.totalNightResets, state.totalAdminEvents, state.totalDeliveries, state.totalThefts, state.totalDrops, state.totalPickups)

        local fullText = table.concat(logLines, "\n")
        logText.Text = fullText
        local textService = game:GetService("TextService")
        local bounds = textService:GetTextSize(fullText, 11, Enum.Font.Code, Vector2.new(580, 100000))
        scroll.CanvasSize = UDim2.new(0, 0, 0, math.max(bounds.Y + 20, scroll.AbsoluteSize.Y))
        scroll.CanvasPosition = Vector2.new(0, scroll.CanvasSize.Y.Offset)
    end

    -- Bottom Action Bar
    local btmBar = Instance.new("Frame")
    btmBar.Size = UDim2.new(1, -16, 0, 36)
    btmBar.Position = UDim2.new(0, 8, 1, -42)
    btmBar.BackgroundTransparency = 1
    btmBar.Parent = mainFrame

    local function createBtn(name, xPos, width, bgCol, onClick)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0, width, 1, 0)
        btn.Position = UDim2.new(0, xPos, 0, 0)
        btn.BackgroundColor3 = bgCol
        btn.Text = name
        btn.TextColor3 = Color3.fromRGB(240, 245, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.Parent = btmBar
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
        local c = btn.MouseButton1Click:Connect(onClick)
        table.insert(state.connections, c)
        return btn
    end

    createBtn("🔄 RESCAN SLOTS", 0, 120, Color3.fromRGB(35, 75, 130), function()
        auditAreaEggSlots(true)
    end)

    createBtn("📋 COPY LOG", 128, 120, Color3.fromRGB(115, 80, 165), function()
        local fullLog = table.concat(logLines, "\n")
        if typeof(setclipboard) == "function" then
            setclipboard(fullLog)
            appendLog("[+] Log copied to clipboard via setclipboard()!")
        else
            appendLog("[-] setclipboard() not supported in this executor.")
        end
    end)

    createBtn("🧪 DUMP MY STATE", 256, 130, Color3.fromRGB(45, 110, 85), function()
        appendLog("--------------------------------------------------")
        appendLog(">>> CURRENT PLAYER & EGG STATE AUDIT:")
        local myChar = LocalPlayer.Character
        local root = myChar and myChar:FindFirstChild("HumanoidRootPart")
        appendLog(string.format("  Player Position: %s", root and formatVector3(root.Position) or "N/A"))
        if state.myCarriedEgg then
            local e = state.myCarriedEgg
            appendLog(string.format("  Currently Carrying: %s [%s] (UID: %s...) Held For: %.1fs",
                e.Species, e.Rarity, e.Uid:sub(1, 8), os.clock() - e.PickedAt))
        else
            appendLog("  Currently Carrying: NONE (Hands free)")
        end
        local totalTracked = 0
        for _ in pairs(state.trackedEggs) do totalTracked = totalTracked + 1 end
        appendLog(string.format("  Total Tracked Eggs in Memory: %d", totalTracked))
        appendLog("--------------------------------------------------")
    end)

    createBtn("🧹 CLEAR", 394, 90, Color3.fromRGB(55, 60, 75), function()
        table.clear(logLines)
        if state.updateLogUI then state.updateLogUI() end
        appendLog("[+] Log cleared.")
    end)

    -- Draggable
    local dragging, dragStart, startPos = false, nil, nil
    local c1 = titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = mainFrame.Position
        end
    end)
    local c2 = UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    local c3 = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    table.insert(state.connections, c1)
    table.insert(state.connections, c2)
    table.insert(state.connections, c3)

    -- Cleanup
    local function cleanup()
        state.alive = false
        for _, conn in ipairs(state.connections) do
            pcall(function() conn:Disconnect() end)
        end
        table.clear(state.connections)
        pcall(function() screenGui:Destroy() end)
        _G.AdvancedEggScanner_Cleanup = nil
    end

    local cClose = closeBtn.MouseButton1Click:Connect(cleanup)
    table.insert(state.connections, cClose)
    _G.AdvancedEggScanner_Cleanup = cleanup

    screenGui.Parent = parent
end

-- ============================================================
-- INITIALIZE
-- ============================================================

buildUI()
appendLog("Advanced Egg Spawn & Interactive Test Case Scanner initialized.")
auditAreaEggSlots(false)
startListeners()
appendLog("[Ready] Monitoring active: Pick up, Drop, Deliver, or watch for Thefts & Resets!")
