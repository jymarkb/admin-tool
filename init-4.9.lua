--[[
    Egg Go-To UI v4 — Snapshot-Powered (Flat List + Rarity Filter + Velocity + Recovery)
    v5.0: Fixed residual movement during ragdoll recovery:
          - Tracks lastGoodCFrame continuously while NOT ragdolled
          - On ragdoll detection, snaps back to lastGoodCFrame BEFORE anchoring
            (cancels out bump/impulse displacement that happened before detection)
          - Hard-anchors HumanoidRootPart during hold + motor-restore phase
            (guarantees zero drift from still-simulating limbs/joints)
          - Added event-based fast detection via Humanoid.StateChanged in addition
            to the Heartbeat poll, to minimize reaction latency after a bump
          - Velocity and Recovery remain fully independent toggles
]]

local ok, err = pcall(function()

--==================================================
-- SERVICES
--==================================================

local Players          = game:GetService("Players")
local Workspace        = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

-- ====================== VELOCITY CONFIG ======================

local velocityEnabled = false
local targetVelocity  = 240.0
local savedWalkSpeed  = 16.0

local zeroFriction = PhysicalProperties.new(0.7, 0, 0, 100, 100)

local originalPhysicalProperties = {}

local connections = {}

local function addConnection(conn)
    table.insert(connections, conn)
    return conn
end

local function disconnectAll()
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(connections)
end

-- ====================== RECOVERY CONFIG ======================

local recoveryEnabled   = true
local recoveryActive    = false
local lastRecoveryTime  = 0

local RECOVERY_STATE = {
    NONE       = "NONE",
    RAGDOLLED  = "RAGDOLLED",
    RECOVERING = "RECOVERING",
}

local recoveryState      = RECOVERY_STATE.NONE
local stopLocation       = nil      -- Vector3 anchor point while ragdolled
local lastMoveDirection  = Vector3.zero
local isRagdolled        = false    -- shared flag, tracked independently of both toggles
local lastGoodCFrame     = nil      -- last confirmed non-ragdolled CFrame

local RAGDOLL_HOLD_TIME  = 0.12     -- brief stabilization window before attempting getup

-- ====================== FRICTION ======================

local function setFrictionless(enable)
    local char = LocalPlayer.Character
    if not char then return end

    for _, desc in ipairs(char:GetDescendants()) do
        if desc:IsA("BasePart") then
            if enable then
                if originalPhysicalProperties[desc] == nil then
                    originalPhysicalProperties[desc] = desc.CustomPhysicalProperties
                end
                pcall(function() desc.CustomPhysicalProperties = zeroFriction end)
            else
                local original = originalPhysicalProperties[desc]
                pcall(function() desc.CustomPhysicalProperties = original end)
                originalPhysicalProperties[desc] = nil
            end
        end
    end
end

-- ====================== EGG DETECTION ======================

local function isHoldingEgg()
    local char = LocalPlayer.Character

    if char then
        for _, child in ipairs(char:GetChildren()) do
            if child:IsA("Tool") or string.find(string.lower(child.Name), "egg") then
                return true
            end
        end
    end

    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if child:IsA("Tool") or string.find(string.lower(child.Name), "egg") then
                return true
            end
        end
    end

    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then
        for _, child in ipairs(cra:GetChildren()) do
            if string.find(child.Name, tostring(LocalPlayer.UserId)) then
                return true
            end
        end
    end

    return false
end

-- ====================== EGG PHYSICS ======================

local function neutraliseEggPhysics(char)
    if not char then return end

    for _, desc in ipairs(char:GetDescendants()) do
        if desc:IsA("BasePart")
            and desc.Name ~= "HumanoidRootPart"
            and desc.Parent ~= char then

            pcall(function()
                desc.Massless = true
                desc.CanCollide = false
            end)
        end
    end

    local cra = Workspace:FindFirstChild("ClientRenderedAssets")
    if cra then
        for _, model in ipairs(cra:GetChildren()) do
            if string.find(model.Name, tostring(LocalPlayer.UserId)) then
                for _, part in ipairs(model:GetDescendants()) do
                    if part:IsA("BasePart") then
                        pcall(function()
                            part.Massless = true
                            part.CanCollide = false
                        end)
                    end
                end
            end
        end
    end
end

-- ====================== RAGDOLL DETECTION ======================

local function getRagdollReason(hum)
    if not hum then return nil end

    local ragdollEnd = LocalPlayer:GetAttribute("RagdollEndTime")
    if typeof(ragdollEnd) == "number" and ragdollEnd > Workspace:GetServerTimeNow() then
        return "RagdollEndTime"
    end

    local state = hum:GetState()
    if state == Enum.HumanoidStateType.Ragdoll then return "Ragdoll" end
    if state == Enum.HumanoidStateType.FallingDown then return "FallingDown" end
    if state == Enum.HumanoidStateType.Physics then return "Physics" end
    if hum.PlatformStand then return "PlatformStand" end

    local char = hum.Parent
    if char then
        local disabledMotors = 0
        local totalMotors = 0

        for _, obj in ipairs(char:GetDescendants()) do
            if obj:IsA("Motor6D") then
                totalMotors += 1
                if not obj.Enabled then disabledMotors += 1 end
            end
        end

        if totalMotors > 0 and disabledMotors >= 2 then
            return string.format("Motor6D:%d disabled", disabledMotors)
        end
    end

    return nil
end

-- ====================== ALWAYS-ON RAGDOLL STATUS ======================
-- Pure detection, no side effects. Runs regardless of either toggle so
-- walkTo() and the UI can always reflect true ragdoll state. Also tracks
-- lastGoodCFrame continuously while NOT ragdolled, so recovery can restore
-- to a pre-bump position.

local function updateRagdollStatus()
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")

    if not hum then
        isRagdolled = false
        return
    end

    if not isRagdolled and root then
        lastGoodCFrame = root.CFrame
    end

    isRagdolled = getRagdollReason(hum) ~= nil
end

-- ====================== RECOVERY ROUTINE ======================
-- Spawned ONCE per ragdoll event (guarded by recoveryActive + recoveryState),
-- not once-per-frame. Aborts early if recoveryEnabled gets switched off
-- mid-routine.

local function recoveryRoutine(hum, root)
    if recoveryActive then return end
    recoveryActive = true

    local char = hum.Parent
    if not char then
        recoveryActive = false
        return
    end

    print("[Recovery Assist] Ragdoll detected — restoring position + anchoring.")

    -- Cancel out any displacement caused by the bump/impulse itself before
    -- we even detected the ragdoll. Without this, anchoring just freezes
    -- you at the already-shoved position.
    if lastGoodCFrame and root and root.Parent then
        pcall(function()
            root.CFrame = lastGoodCFrame
        end)
    end

    -- Hard-anchor the root so NO further drift can occur, regardless of
    -- residual ragdoll velocity/torque being transmitted from other still-
    -- simulating limbs via joints. Velocity-zeroing alone can't guarantee
    -- this since position still integrates for one physics step before
    -- each correction.
    local anchored = false
    pcall(function()
        root.AssemblyLinearVelocity = Vector3.new()
        root.AssemblyAngularVelocity = Vector3.new()
        root.Anchored = true
        anchored = true
    end)

    local function releaseAnchor()
        if anchored and root and root.Parent then
            pcall(function() root.Anchored = false end)
            anchored = false
        end
    end

    -- Phase 1: brief hold while anchored (guarantees zero movement)
    local holdStart = os.clock()
    while os.clock() - holdStart < RAGDOLL_HOLD_TIME do
        if not recoveryEnabled then
            releaseAnchor()
            recoveryActive = false
            return
        end
        task.wait()
    end

    if not recoveryEnabled then
        releaseAnchor()
        recoveryActive = false
        return
    end

    recoveryState = RECOVERY_STATE.RECOVERING

    -- Phase 2: restore motors / humanoid state (still anchored)
    local motorsRestored = 0
    for _, obj in ipairs(char:GetDescendants()) do
        if obj:IsA("Motor6D") and not obj.Enabled then
            pcall(function()
                obj.Enabled = true
                motorsRestored += 1
            end)
        end
    end

    pcall(function() hum.PlatformStand = false end)
    pcall(function() hum.Sit = false end)
    pcall(function() hum.AutoRotate = true end)

    pcall(function()
        hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
        hum:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
    end)

    -- Release right as we hand control back to the Humanoid so GettingUp
    -- can play out naturally instead of fighting an anchored root.
    releaseAnchor()

    pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    task.wait(0.1)

    if hum.Parent then
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Running) end)
    end

    print("[Recovery Assist] Motors restored:", motorsRestored)

    -- Phase 3: confirm the ragdoll condition actually cleared (timeout-guarded)
    local waited = 0
    while getRagdollReason(hum) and waited < 2 do
        task.wait(0.1)
        waited += 0.1
    end

    lastRecoveryTime = os.clock()
    recoveryActive = false
    -- recoveryState gets flipped back to NONE by applyRecovery once it sees
    -- getRagdollReason(hum) == nil.
end

-- ====================== RECOVERY ENGINE (independent of velocity) ======================

local function applyRecovery()
    if not recoveryEnabled then return end

    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")

    if not hum or not root then return end

    local ragdollReason = getRagdollReason(hum)

    if ragdollReason then
        if recoveryState == RECOVERY_STATE.NONE then
            recoveryState = RECOVERY_STATE.RAGDOLLED
            stopLocation = root.Position

            if hum.MoveDirection.Magnitude > 0.05 then
                lastMoveDirection = hum.MoveDirection.Unit
            end

            task.spawn(recoveryRoutine, hum, root)
        end

        -- Fallback dampening if not yet anchored by recoveryRoutine (e.g.
        -- the brief window before the coroutine actually runs). No-op once
        -- the root is anchored.
        if not root.Anchored then
            local horiz = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
            if horiz.Magnitude > 2 then
                pcall(function()
                    root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
                end)
            end
        end
    else
        if recoveryState ~= RECOVERY_STATE.NONE then
            recoveryState = RECOVERY_STATE.NONE
            stopLocation = nil
        end
    end
end

-- ====================== FAST EVENT-BASED RAGDOLL DETECTION ======================
-- Humanoid.StateChanged fires the instant GetState() flips, shaving off the
-- up-to-1-frame latency of polling via Heartbeat. This is the primary
-- trigger; applyRecovery's poll remains as a fallback for the Motor6D-count
-- detection path (which isn't event-driven).

local function bindFastRagdollDetection(hum, root)
    return hum.StateChanged:Connect(function(_, newState)
        if not recoveryEnabled then return end
        if recoveryState ~= RECOVERY_STATE.NONE then return end -- already handling

        local isRagdollState = newState == Enum.HumanoidStateType.Ragdoll
            or newState == Enum.HumanoidStateType.FallingDown
            or newState == Enum.HumanoidStateType.Physics

        if isRagdollState then
            recoveryState = RECOVERY_STATE.RAGDOLLED
            stopLocation = root.Position

            if hum.MoveDirection.Magnitude > 0.05 then
                lastMoveDirection = hum.MoveDirection.Unit
            end

            task.spawn(recoveryRoutine, hum, root)
        end
    end)
end

-- ====================== VELOCITY ENGINE (independent of recovery) ======================
-- Pauses/dampens while isRagdolled is true (regardless of what cleared it —
-- our recovery system, the game's own ragdoll timeout, etc.) and force-
-- resumes the instant isRagdolled flips back to false.

local wasRagdolledForVelocity = false

local function applyVelocity()
    if not velocityEnabled then return end

    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")

    if not hum or not root then return end

    if isRagdolled then
        wasRagdolledForVelocity = true

        if hum.MoveDirection.Magnitude > 0.05 then
            lastMoveDirection = hum.MoveDirection.Unit
        end

        if not root.Anchored then
            local horiz = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
            if horiz.Magnitude > 2 then
                pcall(function()
                    root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
                end)
            end
        end
        return
    end

    if wasRagdolledForVelocity then
        wasRagdolledForVelocity = false

        pcall(function() hum.WalkSpeed = targetVelocity end)

        if lastMoveDirection.Magnitude > 0.05 then
            pcall(function()
                root.AssemblyLinearVelocity = Vector3.new(
                    lastMoveDirection.X * targetVelocity,
                    root.AssemblyLinearVelocity.Y,
                    lastMoveDirection.Z * targetVelocity
                )
            end)
        end

        print("[Velocity] Force-run resumed after ragdoll cleared.")
    end

    if isHoldingEgg() then
        neutraliseEggPhysics(char)
    end

    if hum.WalkSpeed ~= targetVelocity then
        pcall(function() hum.WalkSpeed = targetVelocity end)
    end

    if hum.MoveDirection.Magnitude > 0.05 then
        local dir = hum.MoveDirection.Unit
        lastMoveDirection = dir
        root.AssemblyLinearVelocity = Vector3.new(
            dir.X * targetVelocity,
            root.AssemblyLinearVelocity.Y,
            dir.Z * targetVelocity
        )
    end
end

-- ====================== VELOCITY TOGGLE ======================

local function enableVelocity()
    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")

    if hum then
        savedWalkSpeed = hum.WalkSpeed
    end

    setFrictionless(true)

    if hum then
        pcall(function() hum.WalkSpeed = targetVelocity end)
    end
end

local function disableVelocity()
    setFrictionless(false)

    local char = LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")

    if hum then
        pcall(function() hum.WalkSpeed = savedWalkSpeed end)
    end
end

-- ====================== RARITY CONFIG ======================

local SAFE_ZONE = Vector3.new(536.731, 70, -368.698)

local MUTATION_COLORS = {
    ["Golden"]  = Color3.fromRGB(220, 180, 30),
    ["Rainbow"] = Color3.fromRGB(180, 80, 220),
    ["Silver"]  = Color3.fromRGB(160, 180, 210),
}
local MUTATION_DEFAULT_COLOR = Color3.fromRGB(100, 200, 255)

local ALL_RARITY_ORDER = {
    "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic",
    "Cosmic", "Secret", "Eternal", "Divine", "Unknown",
}

local ALL_RARITY_COLORS = {
    ["Common"]    = Color3.fromRGB(170, 170, 170),
    ["Uncommon"]  = Color3.fromRGB(90,  200, 100),
    ["Rare"]      = Color3.fromRGB(50,  120, 220),
    ["Epic"]      = Color3.fromRGB(140, 60,  220),
    ["Legendary"] = Color3.fromRGB(230, 140, 20),
    ["Mythic"]    = Color3.fromRGB(230, 70,  130),
    ["Cosmic"]    = Color3.fromRGB(70,  170, 255),
    ["Secret"]    = Color3.fromRGB(220, 50,  50),
    ["Eternal"]   = Color3.fromRGB(180, 90,  255),
    ["Divine"]    = Color3.fromRGB(255, 190, 70),
    ["Unknown"]   = Color3.fromRGB(120, 120, 130),
}

local HIGHLIGHT_RARITIES = {
    ["Cosmic"]  = true,
    ["Secret"]  = true,
    ["Eternal"] = true,
    ["Divine"]  = true,
}

local RARITY_DEFAULT_COLOR = Color3.fromRGB(200, 200, 200)

-- ====================== RARITY MONITOR ======================

local rarityByUid = {}

local function startRarityMonitor()
    local rmOk, remote = pcall(function()
        return ReplicatedStorage.Packages.Networking["RE/EggWorld/FieldEggRaritiesShown"]
    end)

    if not rmOk or not remote then return end

    remote.OnClientEvent:Connect(function(payload)
        if typeof(payload) ~= "table" then return end
        local spawns = payload.RareSpawns
        if typeof(spawns) ~= "table" then return end

        for _, entry in pairs(spawns) do
            if typeof(entry) == "table" and entry.EggUid and entry.RarityId then
                rarityByUid[tostring(entry.EggUid)] = tostring(entry.RarityId)
            end
        end
    end)
end
startRarityMonitor()

local PET_RARITY_PRESETS = {
    ["Chicken"] = "Common",
    ["Dog"] = "Common",
    ["Bird"] = "Uncommon",
    ["Owl"] = "Rare",
    ["Raccoon"] = "Rare",
    ["Bear"] = "Epic",
    ["Fox"] = "Epic",
    ["Brr Brr Patapim"] = "Legendary",
    ["Frog"] = "Common",
    ["Duckling"] = "Common",
    ["Catfish"] = "Uncommon",
    ["Turtle"] = "Rare",
    ["Trulimero Trulicina"] = "Epic",
    ["Swan"] = "Epic",
    ["Axolotl"] = "Legendary",
    ["Leviathan"] = "Cosmic",
    ["Jerboa"] = "Common",
    ["Fennec"] = "Uncommon",
    ["Camel"] = "Rare",
    ["Tob Tobi Tob Tob"] = "Epic",
    ["Snake"] = "Legendary",
    ["Scorpion"] = "Mythic",
    ["Sand Spider"] = "Mythic",
    ["Royal Sphinx"] = "Cosmic",
    ["Toucan"] = "Rare",
    ["Chimpanzee"] = "Rare",
    ["Crocodile"] = "Epic",
    ["Gorilla"] = "Legendary",
    ["Orangutini Ananassini"] = "Legendary",
    ["Spider"] = "Mythic",
    ["Tiger"] = "Mythic",
    ["King Snake"] = "Secret",
    ["Penguin"] = "Rare",
    ["Walrus"] = "Epic",
    ["Polar Bear"] = "Legendary",
    ["Sabertooth Tiger"] = "Mythic",
    ["Mammoth"] = "Mythic",
    ["King Mammoth"] = "Cosmic",
    ["Yeti"] = "Secret",
    ["Ice Dragon"] = "Eternal",
    ["Lava Gecko"] = "Rare",
    ["Lava Frog"] = "Epic",
    ["Flaming Bull"] = "Legendary",
    ["Lava Iguana"] = "Legendary",
    ["Chillin Chilli"] = "Mythic",
    ["Cerberus"] = "Secret",
    ["Phoenix"] = "Eternal",
    ["Lava Dragon"] = "Eternal",
    ["Parrotfish"] = "Rare",
    ["Swordfish"] = "Epic",
    ["Shark"] = "Legendary",
    ["Orca"] = "Mythic",
    ["Whale Shark"] = "Cosmic",
    ["Beluga Whale"] = "Cosmic",
    ["Kraken"] = "Secret",
    ["El Maja"] = "Eternal",
    ["Dodo"] = "Rare",
    ["Pterodactyl"] = "Legendary",
    ["Ankylosaurus"] = "Mythic",
    ["Triceratops"] = "Cosmic",
    ["Bronto"] = "Cosmic",
    ["Tralaledon"] = "Secret",
    ["T-Rex"] = "Secret",
    ["Mosasaurus"] = "Eternal",
    ["Centapede"] = "Epic",
    ["Cosmic Gecko"] = "Legendary",
    ["Cosmic Gorilla"] = "Mythic",
    ["La Vacca Saturno Saturnita"] = "Cosmic",
    ["Cosmic Dragon"] = "Secret",
    ["Cosmic Skeleton Boss"] = "Secret",
    ["Eternal Lunar Dragon"] = "Eternal",
    ["Unicorn"] = "Divine",
    ["Crane"] = "Epic",
    ["Salamander"] = "Legendary",
    ["Red Panda"] = "Mythic",
    ["Koi"] = "Cosmic",
    ["Snowy Owl"] = "Cosmic",
    ["Stag"] = "Secret",
    ["Oni Tiger"] = "Eternal",
    ["Kitsune"] = "Divine",
    ["Crustacia"] = "Legendary",
    ["Spideron"] = "Legendary",
    ["Bladehide"] = "Mythic",
    ["Mantaris"] = "Cosmic",
    ["Rhinotaur"] = "Cosmic",
    ["Mutant Shark"] = "Secret",
    ["Gorilla King"] = "Eternal",
    ["Nightflame"] = "Divine",
    ["Light Dove"] = "Legendary",
    ["Winged Lamb"] = "Mythic",
    ["Sacred Moth"] = "Cosmic",
    ["Holy Peacock"] = "Cosmic",
    ["Pure Jellyfish"] = "Secret",
    ["Centaur"] = "Secret",
    ["Pegasus"] = "Eternal",
    ["ArchAngel"] = "Divine",
    ["Flame Sprite"] = "Legendary",
    ["Toro"] = "Mythic",
    ["Imp"] = "Cosmic",
    ["Demon Hound"] = "Cosmic",
    ["Gargoyle"] = "Secret",
    ["RazorFang"] = "Secret",
    ["Skeleton Horse"] = "Eternal",
    ["World Burner"] = "Divine",
    ["Equinox"] = "Eternal",
    ["Aetheron"] = "Divine",
    ["Baby Aurora Dragon"] = "Legendary",
    ["Shadow Dragon"] = "Mythic",
    ["Scorched Dragon"] = "Secret",
    ["Drilla"] = "Cosmic",
    ["Abyss Overlord"] = "Secret",
    ["Void Dragon"] = "Eternal",
    ["Ember Dragon"] = "Secret",
    ["Nibbles #013"] = "Cosmic",
    ["Experiment #001"] = "Secret",
    ["Rift Eye"] = "Legendary",
    ["Void Angler"] = "Legendary",
    ["Riftwing"] = "Mythic",
    ["Shardling"] = "Mythic",
    ["Voidmaw"] = "Mythic",
    ["Dreadclaw"] = "Cosmic",
    ["Shattered Ram"] = "Cosmic",
    ["Ventinal"] = "Cosmic",
    ["Mawbreaker"] = "Secret",
    ["Shardwing"] = "Secret",
    ["Wendigo"] = "Secret",
    ["Shattered Drake"] = "Eternal",
    ["Void Serpent"] = "Eternal",
    ["World Eater"] = "Eternal",
    ["Shattered Colossus"] = "Divine",
    ["Tung Tung Sahur"] = "Rare",
    ["Bananita Dolphinita"] = "Epic",
    ["Belula Beluga"] = "Mythic",
    ["Mangolini Parrochini"] = "Cosmic",
    ["Bomboclat Crocolat"] = "Secret",
    ["Strawberry Elephant"] = "Eternal",
    ["Scorpio"] = "Legendary",
    ["Froggo"] = "Mythic",
    ["Crawler"] = "Cosmic",
    ["Crocodon"] = "Secret",
    ["Krakenoid"] = "Eternal",
    ["Dreadscale"] = "Divine",
    ["Mecha Scorpio"] = "Legendary",
    ["Mecha Froggo"] = "Mythic",
    ["Mecha Crawler"] = "Cosmic",
    ["Mecha Crocodon"] = "Secret",
    ["Mecha Krakenoid"] = "Eternal",
    ["Mecha Dreadscale"] = "Divine",
    ["Spike"] = "Legendary",
    ["Spirit Manta"] = "Mythic",
    ["Abyss Shark"] = "Cosmic",
    ["Electric Eel"] = "Secret",
    ["Terra Snapper"] = "Eternal",
    ["Cthulhu"] = "Divine",
    ["Luminous Spike"] = "Legendary",
    ["Luminous Spirit Manta"] = "Mythic",
    ["Luminous Abyss Shark"] = "Cosmic",
    ["Luminous Electric Eel"] = "Secret",
    ["Luminous Terra Snapper"] = "Eternal",
    ["Luminous Cthulhu"] = "Divine",
}

local function normalizePetName(name)
    local s = tostring(name or ""):lower()
    s = s:gsub("[^%w%s]", " ")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    s = s:gsub("^egg%s+", "")
    s = s:gsub("%s+egg$", "")
    s = s:gsub("^pet%s+", "")
    s = s:gsub("%s+pet$", "")
    return s
end

local presetMatches = {}
for petName, rarity in pairs(PET_RARITY_PRESETS) do
    table.insert(presetMatches, { key = normalizePetName(petName), pet = petName, rarity = rarity })
end
table.sort(presetMatches, function(a, b) return #a.key > #b.key end)

local function getPresetRarity(species)
    local normalized = normalizePetName(species)
    if normalized == "" then return nil, nil end

    for _, entry in ipairs(presetMatches) do
        if normalized == entry.key then return entry.rarity, entry.pet end
    end

    local padded = " " .. normalized .. " "
    for _, entry in ipairs(presetMatches) do
        if padded:find(" " .. entry.key .. " ", 1, true) then return entry.rarity, entry.pet end
    end

    return nil, nil
end

local function resolveEggRawRarity(record)
    if typeof(record) ~= "table" then return nil, nil end

    local species = tostring(record.AssetCategory or "")
    local presetRarity, presetPet = getPresetRarity(species)

    if presetRarity then
        return presetRarity, "Preset: " .. presetPet
    end

    local uid = tostring(record.Uid or "")
    local liveRarity = rarityByUid[uid]
    if liveRarity then
        return liveRarity, "Live UID event"
    end

    return nil, nil
end

local function effectiveRarity(record)
    local rarity = resolveEggRawRarity(record)
    return rarity or "Unknown"
end

local function resolveHighlightRarity(record)
    local rarity, source = resolveEggRawRarity(record)
    if rarity and HIGHLIGHT_RARITIES[rarity] then
        return rarity, source
    end
    return nil, nil
end

-- ====================== FILTER STATE ======================

local selectedFilters = {}
for _, tier in ipairs(ALL_RARITY_ORDER) do
    selectedFilters[tier] = false
end
selectedFilters["Cosmic"]  = true
selectedFilters["Secret"]  = true
selectedFilters["Eternal"] = true
selectedFilters["Divine"]  = true

-- ====================== SNAPSHOT ======================

local function fetchSnapshotRecords()
    local rfOk, remote = pcall(function()
        return ReplicatedStorage.Packages.Networking["RF/EggWorld/AskFieldEggSnapshot"]
    end)

    if not rfOk or not remote then
        return nil, "RF not found"
    end

    local callOk, result = pcall(function()
        return remote:InvokeServer()
    end)

    if not callOk then
        return nil, tostring(result)
    end

    if typeof(result) ~= "table" then
        return nil, "Unexpected return type: " .. typeof(result)
    end

    local records = result.Records
    if typeof(records) ~= "table" then
        return nil, "No Records field in snapshot"
    end

    local all = {}
    for _, record in pairs(records) do
        if typeof(record) == "table" then
            table.insert(all, record)
        end
    end

    table.sort(all, function(a, b)
        local aArea = tostring(a.AreaId or "")
        local bArea = tostring(b.AreaId or "")
        if aArea ~= bArea then return aArea < bArea end
        return tostring(a.NestId) < tostring(b.NestId)
    end)

    return all, nil
end

-- ====================== CARRY ======================

local function getCarryRemote()
    local crOk, remote = pcall(function()
        return ReplicatedStorage.Packages.Networking["RF/EggWorld/AskFieldEggCarry"]
    end)
    return crOk and remote or nil
end

local function carryEgg(uid, statusLabel)
    statusLabel.Text = "Sending carry request..."
    statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

    local remote = getCarryRemote()
    if not remote then
        statusLabel.Text = "Carry remote not found"
        statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
        return false
    end

    local success, cerr = pcall(function()
        remote:InvokeServer({ Uid = uid })
    end)

    if success then
        statusLabel.Text = "Carry request sent!"
        statusLabel.TextColor3 = Color3.fromRGB(120, 255, 150)
        return true
    else
        statusLabel.Text = "Carry failed: " .. tostring(cerr)
        statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
        return false
    end
end

-- ====================== MOVEMENT ======================

local walkToken = 0
local SLOW_ZONE      = 50
local TELEPORT_ZONE  = 50

local function walkTo(destination, arriveRadius, myToken, onArrived)
    task.spawn(function()
        while walkToken == myToken do
            -- Pause movement while ragdolled/recovering so we don't fight
            -- the recovery hold with a CFrame teleport or MoveTo call.
            if isRagdolled then
                task.wait(0.1)
                continue
            end

            local character = LocalPlayer.Character
            if not character then task.wait(0.05) continue end

            local humanoid = character:FindFirstChildOfClass("Humanoid")
            local root     = character:FindFirstChild("HumanoidRootPart")

            if not humanoid or not root then task.wait(0.05) continue end

            local rootPos = root.Position
            local xzDist = Vector3.new(
                destination.X - rootPos.X,
                0,
                destination.Z - rootPos.Z
            ).Magnitude

            if xzDist <= arriveRadius then
                humanoid:Move(Vector3.zero)
                humanoid.WalkToPoint = rootPos
                if onArrived then onArrived() end
                return
            end

            if xzDist <= TELEPORT_ZONE then
                humanoid:Move(Vector3.zero)
                root.CFrame = CFrame.new(destination.X, rootPos.Y, destination.Z)
                task.wait(0.05)
            elseif xzDist > SLOW_ZONE then
                humanoid:MoveTo(destination)
                task.wait(0.2)
            else
                local dir = Vector3.new(
                    destination.X - rootPos.X,
                    0,
                    destination.Z - rootPos.Z
                ).Unit
                humanoid:Move(dir, false)
                task.wait(0.05)
            end
        end
    end)
end

local function returnToSafeZone(myToken, statusLabel)
    statusLabel.Text = "Returning to safe zone..."
    statusLabel.TextColor3 = Color3.fromRGB(100, 180, 255)

    walkTo(SAFE_ZONE, 6, myToken, function()
        if walkToken == myToken then
            statusLabel.Text = "Safe zone reached (OK)"
            statusLabel.TextColor3 = Color3.fromRGB(120, 255, 150)
        end
    end)
end

-- ====================== CARRY CONFIRMATION ======================

local function confirmCarry(uid, timeout)
    local confirmed = false
    local conns = {}

    for _, path in ipairs({ "RE/EggWorld/FieldEggGone", "RE/EggWorld/FieldEggCarry" }) do
        local ccOk, remote = pcall(function()
            return ReplicatedStorage.Packages.Networking[path]
        end)

        if ccOk and remote and remote:IsA("RemoteEvent") then
            table.insert(conns, remote.OnClientEvent:Connect(function(payload)
                if confirmed then return end
                if typeof(payload) == "table" then
                    local payloadUid = tostring(payload.Uid or payload.EggUid or "")
                    if payloadUid == uid then
                        confirmed = true
                    end
                end
            end))
        end
    end

    local elapsed = 0
    while not confirmed and elapsed < timeout do
        local area = Workspace:FindFirstChild("AreaEggSlotsClient")
        if area and not area:FindFirstChild(uid) then
            confirmed = true
            break
        end
        task.wait(0.15)
        elapsed += 0.15
    end

    for _, c in ipairs(conns) do
        pcall(function() c:Disconnect() end)
    end

    return confirmed
end

-- ====================== GET EGG (with retry) ======================

local MAX_CARRY_RETRIES = 3

local function getEgg(position, uid, statusLabel)
    if typeof(position) ~= "Vector3" then return end

    walkToken = walkToken + 1
    local myToken = walkToken

    local function attempt(n)
        if walkToken ~= myToken then return end

        statusLabel.Text = n == 1
            and "Going to egg..."
            or  string.format("Retry %d/%d - going to egg...", n, MAX_CARRY_RETRIES)
        statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

        walkTo(position, 6, myToken, function()
            if walkToken ~= myToken then return end

            statusLabel.Text = "Picking up egg..."
            statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

            local carried = carryEgg(uid, statusLabel)

            if not carried then
                if n < MAX_CARRY_RETRIES then
                    task.wait(0.5)
                    attempt(n + 1)
                else
                    statusLabel.Text = string.format("Carry RF failed after %d tries", MAX_CARRY_RETRIES)
                    statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
                end
                return
            end

            statusLabel.Text = "Confirming pickup..."
            statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

            local confirmed = confirmCarry(uid, 2.5)

            if confirmed then
                task.wait(0.2)
                returnToSafeZone(myToken, statusLabel)
            else
                if n < MAX_CARRY_RETRIES then
                    statusLabel.Text = string.format(
                        "Not confirmed - retry %d/%d...", n + 1, MAX_CARRY_RETRIES)
                    statusLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
                    task.wait(0.5)
                    attempt(n + 1)
                else
                    statusLabel.Text = string.format(
                        "Pickup not confirmed after %d tries", MAX_CARRY_RETRIES)
                    statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
                end
            end
        end)
    end

    attempt(1)
end

-- ====================== HELPERS ======================

local function extractPosition(record)
    local cf = record.BoundsCFrame
    if typeof(cf) == "CFrame" then
        return cf.Position
    end

    local bf = record.BottomCFrame
    if typeof(bf) == "CFrame" then
        return bf.Position
    end

    return nil
end

local function mutationLabel(record)
    if typeof(record.Mutations) ~= "table" then return nil end

    local names = {}
    for _, name in pairs(record.Mutations) do
        if typeof(name) == "string" then
            table.insert(names, name)
        end
    end

    if #names == 0 then return nil end

    table.sort(names)
    return table.concat(names, "+")
end

-- ====================== UI SETUP ======================

local oldGui = PlayerGui:FindFirstChild("EggGoToUI_v4")
if oldGui then oldGui:Destroy() end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "EggGoToUI_v4"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

local main = Instance.new("Frame")
main.Size = UDim2.new(0, 400, 0, 520)
main.Position = UDim2.new(0.5, -200, 0.5, -260)
main.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
main.BorderSizePixel = 0
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(70, 110, 180)
stroke.Thickness = 1.5

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
titleBar.BorderSizePixel = 0
titleBar.Parent = main

Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

local titleFix = Instance.new("Frame")
titleFix.Size = UDim2.new(1, 0, 0, 12)
titleFix.Position = UDim2.new(0, 0, 1, -12)
titleFix.BackgroundColor3 = Color3.fromRGB(32, 40, 60)
titleFix.BorderSizePixel = 0
titleFix.Parent = titleBar

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.new(0, 12, 0, 0)
title.BackgroundTransparency = 1
title.Text = "Egg Go-To v5 + Velocity + Recovery"
title.TextColor3 = Color3.fromRGB(220, 230, 255)
title.TextSize = 14
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 30, 0, 24)
closeBtn.Position = UDim2.new(1, -38, 0.5, -12)
closeBtn.BackgroundColor3 = Color3.fromRGB(170, 50, 50)
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.TextSize = 14
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = titleBar

Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

-- ====================== HEADER: 2-COLUMN LAYOUT ======================
-- Row 1 (y=48):   [Velocity Toggle]  [Value Input]
-- Row 2 (y=82):   [Recovery Toggle]  [Filter Dropdown]
-- Row 3 (y=116):  [Vel Status - full width]
-- Row 4 (y=150):  [Refresh - full width]

local COL_WIDTH = 182   -- each column width
local COL_GAP   = 12    -- gap between the two columns
local ROW_H     = 30
local ROW_STEP  = ROW_H + 4

-- Row 1, Col 1: Velocity toggle
local velToggleBtn = Instance.new("TextButton")
velToggleBtn.Size = UDim2.new(0, COL_WIDTH, 0, ROW_H)
velToggleBtn.Position = UDim2.new(0, 12, 0, 48)
velToggleBtn.BackgroundColor3 = Color3.fromRGB(42, 48, 65)
velToggleBtn.Text = "[OFF] Velocity"
velToggleBtn.TextColor3 = Color3.fromRGB(210, 220, 240)
velToggleBtn.TextSize = 13
velToggleBtn.Font = Enum.Font.GothamBold
velToggleBtn.Parent = main

Instance.new("UICorner", velToggleBtn).CornerRadius = UDim.new(0, 6)

-- Row 1, Col 2: Value input
local velInputBox = Instance.new("TextBox")
velInputBox.Size = UDim2.new(0, COL_WIDTH, 0, ROW_H)
velInputBox.Position = UDim2.new(0, 12 + COL_WIDTH + COL_GAP, 0, 48)
velInputBox.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
velInputBox.Text = tostring(targetVelocity)
velInputBox.PlaceholderText = "Value (e.g. 240)"
velInputBox.TextColor3 = Color3.new(1, 1, 1)
velInputBox.TextSize = 13
velInputBox.Font = Enum.Font.GothamBold
velInputBox.ClearTextOnFocus = false
velInputBox.Parent = main

Instance.new("UICorner", velInputBox).CornerRadius = UDim.new(0, 6)

local velInputStroke = Instance.new("UIStroke", velInputBox)
velInputStroke.Color = Color3.fromRGB(60, 80, 115)
velInputStroke.Thickness = 1

-- Row 2, Col 1: Recovery toggle
local recoveryToggleBtn = Instance.new("TextButton")
recoveryToggleBtn.Size = UDim2.new(0, COL_WIDTH, 0, ROW_H)
recoveryToggleBtn.Position = UDim2.new(0, 12, 0, 48 + ROW_STEP)
recoveryToggleBtn.BackgroundColor3 = Color3.fromRGB(42, 48, 65)
recoveryToggleBtn.Text = "[ON] Recovery"
recoveryToggleBtn.TextColor3 = Color3.new(1, 1, 1)
recoveryToggleBtn.TextSize = 13
recoveryToggleBtn.Font = Enum.Font.GothamBold
recoveryToggleBtn.Parent = main

Instance.new("UICorner", recoveryToggleBtn).CornerRadius = UDim.new(0, 6)

-- Row 2, Col 2: Filter dropdown button
local filterBtn = Instance.new("TextButton")
filterBtn.Size = UDim2.new(0, COL_WIDTH, 0, ROW_H)
filterBtn.Position = UDim2.new(0, 12 + COL_WIDTH + COL_GAP, 0, 48 + ROW_STEP)
filterBtn.BackgroundColor3 = Color3.fromRGB(40, 48, 65)
filterBtn.Text = "Filter: 4 selected v"
filterBtn.TextColor3 = Color3.new(1, 1, 1)
filterBtn.TextSize = 13
filterBtn.Font = Enum.Font.GothamBold
filterBtn.Parent = main

Instance.new("UICorner", filterBtn).CornerRadius = UDim.new(0, 6)

-- Row 3: Velocity status (full width)
local ROW3_Y = 48 + ROW_STEP * 2

local velStatusLabel = Instance.new("TextLabel")
velStatusLabel.Size = UDim2.new(1, -24, 0, ROW_H)
velStatusLabel.Position = UDim2.new(0, 12, 0, ROW3_Y)
velStatusLabel.BackgroundColor3 = Color3.fromRGB(24, 29, 40)
velStatusLabel.Text = "  Vel: 0"
velStatusLabel.TextColor3 = Color3.fromRGB(140, 190, 240)
velStatusLabel.TextSize = 12
velStatusLabel.Font = Enum.Font.GothamBold
velStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
velStatusLabel.Parent = main

Instance.new("UICorner", velStatusLabel).CornerRadius = UDim.new(0, 6)

-- Row 4: Refresh (full width)
local ROW4_Y = ROW3_Y + ROW_STEP

local refreshBtn = Instance.new("TextButton")
refreshBtn.Size = UDim2.new(1, -24, 0, ROW_H)
refreshBtn.Position = UDim2.new(0, 12, 0, ROW4_Y)
refreshBtn.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
refreshBtn.Text = "Refresh All Eggs"
refreshBtn.TextColor3 = Color3.new(1, 1, 1)
refreshBtn.TextSize = 13
refreshBtn.Font = Enum.Font.GothamBold
refreshBtn.Parent = main

Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(0, 6)

-- Filter dropdown list (appears below filterBtn, right column)
local filterList = Instance.new("Frame")
filterList.Size = UDim2.new(0, COL_WIDTH, 0, 0)
filterList.Position = UDim2.new(0, 12 + COL_WIDTH + COL_GAP, 0, 48 + ROW_STEP * 2)
filterList.BackgroundColor3 = Color3.fromRGB(30, 36, 50)
filterList.BorderSizePixel = 0
filterList.ClipsDescendants = true
filterList.Visible = false
filterList.ZIndex = 20
filterList.Parent = main

Instance.new("UICorner", filterList).CornerRadius = UDim.new(0, 6)

local filterLayout = Instance.new("UIListLayout")
filterLayout.Parent = filterList

-- Status
local STATUS_Y = ROW4_Y + ROW_H + 8

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -24, 0, 22)
statusLabel.Position = UDim2.new(0, 12, 0, STATUS_Y)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Click Refresh to load all eggs"
statusLabel.TextColor3 = Color3.fromRGB(180, 195, 220)
statusLabel.TextSize = 12
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = main

-- Egg list
local LIST_Y = STATUS_Y + 26

local listFrame = Instance.new("ScrollingFrame")
listFrame.Size = UDim2.new(1, -24, 1, -(LIST_Y + 12))
listFrame.Position = UDim2.new(0, 12, 0, LIST_Y)
listFrame.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
listFrame.BorderSizePixel = 0
listFrame.ScrollBarThickness = 6
listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
listFrame.Parent = main

Instance.new("UICorner", listFrame).CornerRadius = UDim.new(0, 8)

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 6)
listLayout.Parent = listFrame

-- Drag
local dragging, dragStart, startPos

titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = main.Position
    end
end)

titleBar.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end
end)

-- ====================== EGG CARD ======================

local CARD_HEIGHT = 90

local function makeBadge(parent, text, color, xOffset, yOffset)
    local badge = Instance.new("TextLabel")
    badge.Size = UDim2.new(0, 0, 0, 16)
    badge.AutomaticSize = Enum.AutomaticSize.X
    badge.Position = UDim2.new(0, xOffset, 0, yOffset)
    badge.BackgroundColor3 = color
    badge.BackgroundTransparency = 0
    badge.Text = " " .. text .. " "
    badge.TextColor3 = Color3.new(1, 1, 1)
    badge.TextSize = 10
    badge.Font = Enum.Font.GothamBold
    badge.TextXAlignment = Enum.TextXAlignment.Center
    badge.Parent = parent

    Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 4)
    return badge
end

local function createEggCard(index, record)
    local uid      = tostring(record.Uid or "")
    local species  = tostring(record.AssetCategory or "Unknown")
    local slot     = tostring(record.NestId or "?")
    local biome    = tostring(record.AreaId or "?")
    local scale    = record.AssetScale
    local position = extractPosition(record)
    local mutation = mutationLabel(record)

    local rarity, raritySource = resolveHighlightRarity(record)
    _ = raritySource

    local bgColor = Color3.fromRGB(28, 32, 42)
    if rarity then
        bgColor = Color3.fromRGB(50, 20, 20)
    end

    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, -12, 0, CARD_HEIGHT)
    card.BackgroundColor3 = bgColor
    card.BorderSizePixel = 0
    card.Parent = listFrame

    Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)

    if rarity then
        local stripe = Instance.new("Frame")
        stripe.Size = UDim2.new(0, 4, 1, 0)
        stripe.Position = UDim2.new(0, 0, 0, 0)
        stripe.BackgroundColor3 = ALL_RARITY_COLORS[rarity] or RARITY_DEFAULT_COLOR
        stripe.BorderSizePixel = 0
        stripe.Parent = card

        Instance.new("UICorner", stripe).CornerRadius = UDim.new(0, 4)
    end

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, -96, 0, 18)
    nameLabel.Position = UDim2.new(0, 10, 0, 6)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = string.format("#%d  %s", index, species)
    nameLabel.TextColor3 = rarity and Color3.fromRGB(255, 200, 200) or Color3.fromRGB(220, 230, 255)
    nameLabel.TextSize = 13
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
    nameLabel.Parent = card

    local biomeLabel = Instance.new("TextLabel")
    biomeLabel.Size = UDim2.new(1, -96, 0, 14)
    biomeLabel.Position = UDim2.new(0, 10, 0, 24)
    biomeLabel.BackgroundTransparency = 1
    biomeLabel.Text = biome .. "  |  " .. slot
    biomeLabel.TextColor3 = Color3.fromRGB(140, 190, 230)
    biomeLabel.TextSize = 11
    biomeLabel.Font = Enum.Font.GothamBold
    biomeLabel.TextXAlignment = Enum.TextXAlignment.Left
    biomeLabel.Parent = card

    local scaleText = scale and string.format("x%.2f", scale) or ""
    local infoLabel = Instance.new("TextLabel")
    infoLabel.Size = UDim2.new(1, -96, 0, 14)
    infoLabel.Position = UDim2.new(0, 10, 0, 40)
    infoLabel.BackgroundTransparency = 1
    infoLabel.Text = scaleText
    infoLabel.TextColor3 = Color3.fromRGB(150, 165, 190)
    infoLabel.TextSize = 11
    infoLabel.Font = Enum.Font.Code
    infoLabel.TextXAlignment = Enum.TextXAlignment.Left
    infoLabel.Parent = card

    local posLabel = Instance.new("TextLabel")
    posLabel.Size = UDim2.new(1, -96, 0, 14)
    posLabel.Position = UDim2.new(0, 10, 0, 56)
    posLabel.BackgroundTransparency = 1
    posLabel.Text = position
        and string.format("(%.0f, %.0f, %.0f)", position.X, position.Y, position.Z)
        or  "pos unknown"
    posLabel.TextColor3 = Color3.fromRGB(120, 135, 160)
    posLabel.TextSize = 10
    posLabel.Font = Enum.Font.Code
    posLabel.TextXAlignment = Enum.TextXAlignment.Left
    posLabel.Parent = card

    local badgeOffsetX = 10
    if mutation then
        local mutColor = MUTATION_COLORS[mutation] or MUTATION_DEFAULT_COLOR
        makeBadge(card, mutation, mutColor, badgeOffsetX, 72)
        badgeOffsetX = badgeOffsetX + #mutation * 7 + 18
    end

    if rarity then
        makeBadge(card, rarity, ALL_RARITY_COLORS[rarity] or RARITY_DEFAULT_COLOR, badgeOffsetX, 72)
    end

    local getBtn = Instance.new("TextButton")
    getBtn.Size = UDim2.new(0, 70, 0, 34)
    getBtn.Position = UDim2.new(1, -82, 0.5, -17)
    getBtn.BackgroundColor3 = Color3.fromRGB(40, 130, 80)
    getBtn.Text = "Get"
    getBtn.TextColor3 = Color3.new(1, 1, 1)
    getBtn.TextSize = 13
    getBtn.Font = Enum.Font.GothamBold
    getBtn.Parent = card

    Instance.new("UICorner", getBtn).CornerRadius = UDim.new(0, 6)

    getBtn.MouseButton1Click:Connect(function()
        if position then
            getEgg(position, uid, statusLabel)
        else
            statusLabel.Text = "No position for this egg"
            statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
        end
    end)
end

-- ====================== RENDER / FILTER ======================

local lastRecords = {}

local function clearList()
    for _, child in ipairs(listFrame:GetChildren()) do
        if child:IsA("Frame") then child:Destroy() end
    end
end

local function renderList()
    clearList()

    local filtered = {}
    for _, record in ipairs(lastRecords) do
        local tier = effectiveRarity(record)
        if selectedFilters[tier] then
            table.insert(filtered, record)
        end
    end

    if #filtered == 0 then
        if #lastRecords == 0 then
            statusLabel.Text = "Click Refresh to load all eggs"
            statusLabel.TextColor3 = Color3.fromRGB(180, 195, 220)
        else
            statusLabel.Text = "No eggs match current filter"
            statusLabel.TextColor3 = Color3.fromRGB(255, 160, 100)
        end
        listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
        return
    end

    for i, record in ipairs(filtered) do
        createEggCard(i, record)
    end

    listFrame.CanvasSize = UDim2.new(0, 0, 0, #filtered * (CARD_HEIGHT + 6))

    local mutCount    = 0
    local rarityCount = 0

    for _, record in ipairs(filtered) do
        if mutationLabel(record) then mutCount += 1 end
        local hl = select(1, resolveHighlightRarity(record))
        if hl then rarityCount += 1 end
    end

    local summary = string.format("%d / %d egg(s) shown", #filtered, #lastRecords)

    if mutCount > 0 then
        summary = summary .. string.format(" | %d mutated", mutCount)
    end

    if rarityCount > 0 then
        summary = summary .. string.format(" | %d RARE", rarityCount)
    end

    statusLabel.Text = summary
    statusLabel.TextColor3 = rarityCount > 0
        and Color3.fromRGB(255, 120, 120)
        or  Color3.fromRGB(120, 255, 150)
end

local function scanEggs()
    clearList()
    statusLabel.Text = "Fetching all eggs..."
    statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)

    task.spawn(function()
        local records, ferr = fetchSnapshotRecords()

        if not records then
            statusLabel.Text = "Error: " .. tostring(ferr)
            statusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
            return
        end

        lastRecords = records
        renderList()
    end)
end

-- ====================== FILTER DROPDOWN ======================

local function updateFilterButtonText()
    local count = 0
    for _, v in pairs(selectedFilters) do
        if v then count += 1 end
    end
    filterBtn.Text = string.format("Filter: %d selected %s", count, filterList.Visible and "^" or "v")
end

local filterItemButtons = {}

local function refreshFilterItemVisuals()
    for tier, btn in pairs(filterItemButtons) do
        local checked = selectedFilters[tier]
        btn.Text = (checked and "[X] " or "[ ] ") .. tier
    end
    updateFilterButtonText()
end

local quickRow = Instance.new("Frame")
quickRow.Size = UDim2.new(1, 0, 0, 26)
quickRow.BackgroundTransparency = 1
quickRow.Parent = filterList

local allBtn = Instance.new("TextButton")
allBtn.Size = UDim2.new(0.5, -2, 1, -4)
allBtn.Position = UDim2.new(0, 2, 0, 2)
allBtn.BackgroundColor3 = Color3.fromRGB(45, 100, 160)
allBtn.Text = "All"
allBtn.TextColor3 = Color3.new(1, 1, 1)
allBtn.TextSize = 12
allBtn.Font = Enum.Font.GothamBold
allBtn.Parent = quickRow
Instance.new("UICorner", allBtn).CornerRadius = UDim.new(0, 4)

local noneBtn = Instance.new("TextButton")
noneBtn.Size = UDim2.new(0.5, -2, 1, -4)
noneBtn.Position = UDim2.new(0.5, 0, 0, 2)
noneBtn.BackgroundColor3 = Color3.fromRGB(90, 45, 45)
noneBtn.Text = "None"
noneBtn.TextColor3 = Color3.new(1, 1, 1)
noneBtn.TextSize = 12
noneBtn.Font = Enum.Font.GothamBold
noneBtn.Parent = quickRow
Instance.new("UICorner", noneBtn).CornerRadius = UDim.new(0, 4)

allBtn.MouseButton1Click:Connect(function()
    for _, tier in ipairs(ALL_RARITY_ORDER) do selectedFilters[tier] = true end
    refreshFilterItemVisuals()
    renderList()
end)

noneBtn.MouseButton1Click:Connect(function()
    for _, tier in ipairs(ALL_RARITY_ORDER) do selectedFilters[tier] = false end
    refreshFilterItemVisuals()
    renderList()
end)

for _, tier in ipairs(ALL_RARITY_ORDER) do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 26)
    btn.BackgroundColor3 = Color3.fromRGB(40, 48, 65)
    btn.Text = (selectedFilters[tier] and "[X] " or "[ ] ") .. tier
    btn.TextColor3 = ALL_RARITY_COLORS[tier] or Color3.new(1, 1, 1)
    btn.TextSize = 13
    btn.Font = Enum.Font.GothamBold
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.Parent = filterList

    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 10)
    pad.Parent = btn

    filterItemButtons[tier] = btn

    btn.MouseButton1Click:Connect(function()
        selectedFilters[tier] = not selectedFilters[tier]
        refreshFilterItemVisuals()
        renderList()
    end)
end

local filterOpen = false

local function toggleFilterDropdown()
    filterOpen = not filterOpen
    filterList.Visible = filterOpen

    if filterOpen then
        local itemCount = #ALL_RARITY_ORDER
        filterList.Size = UDim2.new(0, COL_WIDTH, 0, 26 + itemCount * 26)
    else
        filterList.Size = UDim2.new(0, COL_WIDTH, 0, 0)
    end

    updateFilterButtonText()
end

filterBtn.MouseButton1Click:Connect(toggleFilterDropdown)

refreshFilterItemVisuals()

refreshBtn.MouseButton1Click:Connect(scanEggs)

-- ====================== VELOCITY BINDINGS ======================

local function updateVelocityButtonText()
    if velocityEnabled then
        velToggleBtn.Text = string.format("[ON] Vel: %d", targetVelocity)
        velToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
        velToggleBtn.TextColor3 = Color3.new(1, 1, 1)
    else
        velToggleBtn.Text = "[OFF] Velocity"
        velToggleBtn.BackgroundColor3 = Color3.fromRGB(42, 48, 65)
        velToggleBtn.TextColor3 = Color3.fromRGB(210, 220, 240)
    end
end

local function updateVelocityFromInput()
    local value = tonumber(velInputBox.Text)
    if value and value > 0 then
        targetVelocity = value
        velInputStroke.Color = Color3.fromRGB(60, 140, 240)
        updateVelocityButtonText()
    else
        velInputBox.Text = tostring(targetVelocity)
        velInputStroke.Color = Color3.fromRGB(60, 80, 115)
    end
end

velInputBox.FocusLost:Connect(updateVelocityFromInput)

velInputBox:GetPropertyChangedSignal("Text"):Connect(function()
    local value = tonumber(velInputBox.Text)
    if value and value > 0 then
        targetVelocity = value
    end
end)

velToggleBtn.MouseButton1Click:Connect(function()
    updateVelocityFromInput()

    velocityEnabled = not velocityEnabled

    if velocityEnabled then
        enableVelocity()
    else
        disableVelocity()
    end

    updateVelocityButtonText()
end)

-- ====================== RECOVERY BINDINGS ======================

local function updateRecoveryButtonText()
    if recoveryEnabled then
        recoveryToggleBtn.Text = "[ON] Recovery"
        recoveryToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
        recoveryToggleBtn.TextColor3 = Color3.new(1, 1, 1)
    else
        recoveryToggleBtn.Text = "[OFF] Recovery"
        recoveryToggleBtn.BackgroundColor3 = Color3.fromRGB(42, 48, 65)
        recoveryToggleBtn.TextColor3 = Color3.fromRGB(210, 220, 240)
    end
end

recoveryToggleBtn.MouseButton1Click:Connect(function()
    recoveryEnabled = not recoveryEnabled

    if not recoveryEnabled then
        -- Reset bookkeeping so re-enabling later starts clean instead of
        -- thinking it's already mid-recovery.
        recoveryState = RECOVERY_STATE.NONE
        stopLocation = nil
    end

    updateRecoveryButtonText()
end)

updateRecoveryButtonText()

-- Velocity/Recovery status updater (Heartbeat)
addConnection(
    RunService.Heartbeat:Connect(function()
        local char = LocalPlayer.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        local root = char and char:FindFirstChild("HumanoidRootPart")

        if not hum or not root then
            velStatusLabel.Text = "  Vel: --"
            return
        end

        local horizVel = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
        local vel = math.floor(horizVel.Magnitude)

        if isRagdolled then
            local tag = recoveryEnabled and "RECOVERY" or "RAGDOLL"
            velStatusLabel.Text = string.format("  Vel: %d | %s", vel, tag)
            velStatusLabel.TextColor3 = Color3.fromRGB(255, 180, 80)
        else
            local egg = isHoldingEgg()
            velStatusLabel.Text = string.format(
                "  Vel: %d%s%s",
                vel,
                egg and " | Egg" or "",
                recoveryActive and " | Recovering" or ""
            )
            velStatusLabel.TextColor3 = velocityEnabled
                and Color3.fromRGB(100, 240, 255)
                or  Color3.fromRGB(140, 190, 240)
        end
    end)
)

-- ====================== ENGINE LOOPS ======================
-- Order matters: status first, then recovery, then velocity, so both feature
-- loops see a fresh isRagdolled value for the current frame.

addConnection(RunService.Heartbeat:Connect(updateRagdollStatus))
addConnection(RunService.Heartbeat:Connect(applyRecovery))
addConnection(RunService.Heartbeat:Connect(applyVelocity))

-- ====================== CLOSE BUTTON ======================

addConnection(
    closeBtn.MouseButton1Click:Connect(function()
        velocityEnabled = false
        recoveryEnabled = false
        disableVelocity()
        disconnectAll()
        screenGui:Destroy()
    end)
)

-- ====================== RESPAWN ======================

addConnection(
    LocalPlayer.CharacterAdded:Connect(function(char)
        task.wait(0.5)

        recoveryActive         = false
        lastRecoveryTime       = 0
        recoveryState          = RECOVERY_STATE.NONE
        stopLocation            = nil
        lastMoveDirection       = Vector3.zero
        isRagdolled             = false
        wasRagdolledForVelocity = false
        lastGoodCFrame          = nil

        local hum  = char:FindFirstChildOfClass("Humanoid")
        local root = char:FindFirstChild("HumanoidRootPart")
        if hum and root then
            addConnection(bindFastRagdollDetection(hum, root))
        end

        if velocityEnabled then
            setFrictionless(true)
            if hum then savedWalkSpeed = hum.WalkSpeed end
        end
    end)
)

-- Bind fast detection for the character that already exists at script load
-- (CharacterAdded won't fire again for an already-spawned character).
do
    local char = LocalPlayer.Character
    if char then
        local hum  = char:FindFirstChildOfClass("Humanoid")
        local root = char:FindFirstChild("HumanoidRootPart")
        if hum and root then
            addConnection(bindFastRagdollDetection(hum, root))
        end
    end
end

-- Auto scan on load
task.defer(scanEggs)

print("[EggGoToUI v5] Loaded.")
print("[Recovery Assist] Enabled: " .. tostring(recoveryEnabled) .. " (independent toggle)")
print("[Velocity] Enabled: " .. tostring(velocityEnabled) .. " | Target: " .. targetVelocity .. " (independent toggle)")

end)

if not ok then
    warn("[EggGoToUI] FAILED TO LOAD: " .. tostring(err))
end