--[[
    STEAL AN EGG - TARGETED CHARACTER SCANNER
    Target: Kaihii (configurable in UI)
    Mode: READ-ONLY (Queries character details, player data, workspace entities, base plot, and profile remotes)
    
    Targeted specifically to inspect and diagnose:
      1. Target Player Overview (UserId, DisplayName, AccountAge, Attributes, leaderstats, replicated folders/backpack)
      2. Character & Humanoid Rig (Position, Health, WalkSpeed, MoveDirection, State, Animations, Accessories, Welds)
      3. Held Tool & Carried Egg Detection (Tool attributes, ItemType, UID, carried egg models, carrier attributes)
      4. Base Plot & Placed Eggs (Workspace.Plots ownership, Workspace.PlacedEggRenders.<UserId>_<EggUid>)
      5. Associated Follower Pets & Entities in Workspace (Workspace.Pets, proximity followers, species, weight, earn)
      6. Server Remote Probing (Safe read-only targeted queries to ProfileMirror & PenRoster)
      7. Executive Target Summary
    
    Features:
      - Interactive draggable dark-mode UI with live status indicator
      - Dynamic Target Input Box (defaults to "Kaihii")
      - One-click Player Chips to switch between online players
      - One-click "COPY" (setclipboard support)
      - One-click "SAVE FILE" (writefile to targeted-kaihii-scan.log)
      - Monospace scrollable output viewer
      - Safe pcall sandboxing on every section
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- Guaranteed visible UI mount
local function getGuiParent()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then return pg end
    local ok, h = pcall(function() return (typeof(gethui) == "function" and gethui()) or CoreGui end)
    if ok and h then return h end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local uiParent = getGuiParent()

-- Destroy previous scanner instance if open
local existingGui = uiParent:FindFirstChild("TargetedCharacterScannerGui")
if existingGui then
    pcall(function() existingGui:Destroy() end)
end

-- ============================================================
-- HELPER FUNCTIONS FOR CLEAN FORMATTING
-- ============================================================

local function safeValStr(v)
    local t = typeof(v)
    if t == "Instance" then
        return string.format("<Instance: %s [%s]>", v:GetFullName(), v.ClassName)
    elseif t == "Vector3" then
        return string.format("Vector3(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
    elseif t == "CFrame" then
        local p = v.Position
        return string.format("CFrame(%.2f, %.2f, %.2f)", p.X, p.Y, p.Z)
    elseif t == "Color3" then
        return string.format("Color3(%.2f, %.2f, %.2f)", v.R, v.G, v.B)
    elseif t == "string" then
        return string.format("%q", v)
    else
        return tostring(v)
    end
end

local function dumpTable(tbl, maxDepth, indent, visited)
    maxDepth = maxDepth or 3
    indent = indent or "  "
    visited = visited or {}

    if type(tbl) ~= "table" then
        return safeValStr(tbl)
    end
    if visited[tbl] then
        return "<circular reference>"
    end
    visited[tbl] = true

    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    if count == 0 then return "{}" end

    local keys = {}
    for k in pairs(tbl) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local lines = {}
    table.insert(lines, string.format("{ -- %d entries", count))
    for i, k in ipairs(keys) do
        if i > 50 then
            table.insert(lines, indent .. string.format("... (%d more entries truncated)", count - 50))
            break
        end
        local v = tbl[k]
        local keyStr = tostring(k)
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
            keyStr = k
        else
            keyStr = "[" .. safeValStr(k) .. "]"
        end

        if type(v) == "table" then
            if maxDepth > 1 then
                local nested = dumpTable(v, maxDepth - 1, indent .. "  ", visited)
                table.insert(lines, indent .. keyStr .. " = " .. nested)
            else
                local subCount = 0
                for _ in pairs(v) do subCount = subCount + 1 end
                table.insert(lines, indent .. keyStr .. string.format(" = <Table: %d items>", subCount))
            end
        else
            table.insert(lines, indent .. keyStr .. " = " .. safeValStr(v) .. " [" .. typeof(v) .. "]")
        end
    end
    table.insert(lines, string.sub(indent, 1, math.max(0, #indent - 2)) .. "}")
    return table.concat(lines, "\n")
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

-- ============================================================
-- TARGET RESOLVER
-- ============================================================

local function resolveTarget(queryName)
    queryName = (queryName or "Kaihii"):gsub("^%s+", ""):gsub("%s+$", "")
    local qLower = queryName:lower()
    local targetPlr, targetChar

    -- 1. Search Players service by exact Username or DisplayName
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower() == qLower or p.DisplayName:lower() == qLower then
            targetPlr = p
            targetChar = p.Character
            break
        end
    end

    -- 2. Substring match on Players service
    if not targetPlr then
        for _, p in ipairs(Players:GetPlayers()) do
            if string.find(p.Name:lower(), qLower, 1, true) or string.find(p.DisplayName:lower(), qLower, 1, true) then
                targetPlr = p
                targetChar = p.Character
                break
            end
        end
    end

    -- 3. Search Workspace for Character Model if not found via Player
    if not targetChar then
        for _, obj in ipairs(Workspace:GetChildren()) do
            if obj:IsA("Model") and (obj:FindFirstChildOfClass("Humanoid") or obj:FindFirstChild("HumanoidRootPart")) then
                if obj.Name:lower() == qLower or string.find(obj.Name:lower(), qLower, 1, true) then
                    targetChar = obj
                    break
                end
            end
        end
    end

    -- 4. Search common sub-containers in Workspace
    if not targetChar then
        local containers = {
            Workspace:FindFirstChild("Characters"),
            Workspace:FindFirstChild("Entities"),
            Workspace:FindFirstChild("Players"),
            Workspace:FindFirstChild("Rigs"),
            Workspace:FindFirstChild("NPCs")
        }
        for _, c in ipairs(containers) do
            if c then
                for _, obj in ipairs(c:GetChildren()) do
                    if obj:IsA("Model") and (obj.Name:lower() == qLower or string.find(obj.Name:lower(), qLower, 1, true)) then
                        targetChar = obj
                        break
                    end
                end
            end
            if targetChar then break end
        end
    end

    return targetPlr, targetChar
end

-- ============================================================
-- CORE SCAN LOGIC
-- ============================================================

local function runTargetedScan(targetQuery, onProgress)
    local out = {}
    local function log(s)
        table.insert(out, tostring(s or ""))
    end
    local function progress(txt)
        if onProgress then pcall(onProgress, txt) end
    end

    targetQuery = (targetQuery or "Kaihii"):gsub("^%s+", ""):gsub("%s+$", "")
    progress("Resolving target: " .. targetQuery .. "...")

    log("==================================================")
    log("STEAL AN EGG - TARGETED CHARACTER SCANNER")
    log("TARGET QUERY: " .. targetQuery)
    log("TIMESTAMP:    " .. os.date("!%Y-%m-%dT%H:%M:%SZ"))
    log("SCANNER RUNNER: " .. tostring(LocalPlayer.Name) .. " (UserId: " .. tostring(LocalPlayer.UserId) .. ")")
    log("==================================================")
    log("")

    local targetPlr, targetChar = resolveTarget(targetQuery)
    local myChar = LocalPlayer.Character
    local myHrp = myChar and (myChar:FindFirstChild("HumanoidRootPart") or myChar.PrimaryPart)
    local myPos = myHrp and myHrp.Position

    -- ----------------------------------------------------
    -- 0. RESOLUTION SUMMARY
    -- ----------------------------------------------------
    log("===== 0. TARGET RESOLUTION STATUS =====")
    if targetPlr then
        log("Player Status:        [ONLINE] Found in game.Players")
        log("Username:             " .. targetPlr.Name)
        log("DisplayName:          " .. targetPlr.DisplayName)
        log("UserId:               " .. tostring(targetPlr.UserId))
        log("AccountAge:           " .. tostring(targetPlr.AccountAge) .. " days")
        log("MembershipType:       " .. tostring(targetPlr.MembershipType))
    else
        log("Player Status:        [NOT IN PLAYERS LIST] (No Player object matching '" .. targetQuery .. "')")
    end

    if targetChar then
        log("Character Status:     [SPAWNED] Model exists in Workspace")
        log("Character Model Name: " .. targetChar.Name)
        log("Character FullName:   " .. targetChar:GetFullName())
        local targetHrp = targetChar:FindFirstChild("HumanoidRootPart") or targetChar.PrimaryPart
        if targetHrp and myPos then
            local dist = (targetHrp.Position - myPos).Magnitude
            log(string.format("Position:             (%.2f, %.2f, %.2f)", targetHrp.Position.X, targetHrp.Position.Y, targetHrp.Position.Z))
            log(string.format("Distance from Runner: %.2f studs", dist))
        elseif targetHrp then
            log(string.format("Position:             (%.2f, %.2f, %.2f)", targetHrp.Position.X, targetHrp.Position.Y, targetHrp.Position.Z))
        end
    else
        log("Character Status:     [NOT FOUND] Character model not found in Workspace.")
    end
    log("")

    -- List all online players for convenience if target not found
    if not targetPlr then
        log("--- Currently Connected Players in Server ---")
        local allPlrs = Players:GetPlayers()
        log(string.format("Total Players Online: %d", #allPlrs))
        for idx, p in ipairs(allPlrs) do
            local hasChar = (p.Character and p.Character:FindFirstChild("HumanoidRootPart")) and "Spawned" or "No Char"
            log(string.format("  [%d] %s (@%s) | UserId: %d | Status: %s", idx, p.DisplayName, p.Name, p.UserId, hasChar))
        end
        log("")
    end

    -- ----------------------------------------------------
    -- 1. TARGET PLAYER OVERVIEW & REPLICATED DATA
    -- ----------------------------------------------------
    if targetPlr then
        progress("Inspecting Player data & attributes...")
        log("===== 1. TARGET PLAYER DATA & REPLICATED CONTAINERS =====")

        -- Attributes
        log("--- Player Attributes ---")
        local pAttrs = targetPlr:GetAttributes()
        local pAttrKeys = {}
        for k in pairs(pAttrs) do table.insert(pAttrKeys, k) end
        table.sort(pAttrKeys)
        if #pAttrKeys == 0 then
            log("  (none)")
        else
            for _, k in ipairs(pAttrKeys) do
                log(string.format("  %s = %s [%s]", k, safeValStr(pAttrs[k]), typeof(pAttrs[k])))
            end
        end
        log("")

        -- Leaderstats
        log("--- Leaderstats Values ---")
        local leaderstats = targetPlr:FindFirstChild("leaderstats")
        if leaderstats then
            for _, s in ipairs(leaderstats:GetChildren()) do
                local val = s:IsA("ValueBase") and tostring(s.Value) or tostring(s)
                log(string.format("  %s = %s [%s]", s.Name, val, s.ClassName))
            end
        else
            log("  (leaderstats folder not found or not replicated)")
        end
        log("")

        -- Player Direct Children (Folders, ValueObjects, Backpack)
        log("--- Player Child Folders & Objects ---")
        local pChildren = targetPlr:GetChildren()
        table.sort(pChildren, function(a, b) return a.Name < b.Name end)
        for _, ch in ipairs(pChildren) do
            if ch:IsA("ValueBase") then
                log(string.format("  [%s] %s = %s", ch.ClassName, ch.Name, safeValStr(ch.Value)))
            elseif ch:IsA("Folder") or ch:IsA("Configuration") then
                local subChildren = ch:GetChildren()
                log(string.format("  [%s] %s (%d items):", ch.ClassName, ch.Name, #subChildren))
                for _, sub in ipairs(subChildren) do
                    if sub:IsA("ValueBase") then
                        log(string.format("    - [%s] %s = %s", sub.ClassName, sub.Name, safeValStr(sub.Value)))
                    else
                        local subAttrs = sub:GetAttributes()
                        local attrParts = {}
                        for ak, av in pairs(subAttrs) do table.insert(attrParts, string.format("%s=%s", ak, safeValStr(av))) end
                        local attrStr = #attrParts > 0 and (" | Attrs: " .. table.concat(attrParts, ", ")) or ""
                        log(string.format("    - [%s] %s (%d sub-items)%s", sub.ClassName, sub.Name, #sub:GetChildren(), attrStr))
                    end
                end
            elseif ch:IsA("Backpack") then
                local tools = ch:GetChildren()
                log(string.format("  [Backpack] %d Tools/Items:", #tools))
                for _, t in ipairs(tools) do
                    local tAttrs = t:GetAttributes()
                    local dName = tostring(tAttrs.DisplayName or t.Name)
                    local cat = tostring(tAttrs.Category or "")
                    local itemType = tostring(tAttrs.ItemType or "")
                    local uid = tostring(tAttrs.UID or tAttrs.Uid or tAttrs.EggUID or "")
                    local isEgg = dName:lower():find("egg") or cat:lower() == "egg" or itemType == "Egg" or tAttrs.IsEgg == true
                    local eggTag = isEgg and " [🥚 EGG]" or ""
                    log(string.format("    - [%s] %s%s (Type: %s, Cat: %s, UID: %s)", t.ClassName, dName, eggTag, itemType, cat, uid))
                    for ak, av in pairs(tAttrs) do
                        if ak ~= "DisplayName" and ak ~= "Category" and ak ~= "ItemType" and ak ~= "UID" then
                            log(string.format("        attr %s = %s", ak, safeValStr(av)))
                        end
                    end
                end
            else
                log(string.format("  [%s] %s", ch.ClassName, ch.Name))
            end
        end
        log("")
    end

    -- ----------------------------------------------------
    -- 2. TARGET CHARACTER & RIG DEEP INSPECTION
    -- ----------------------------------------------------
    if targetChar then
        progress("Deep-inspecting Character rig and humanoid...")
        log("===== 2. TARGET CHARACTER RIG & HUMANOID DEEP INSPECTION =====")
        local hum = targetChar:FindFirstChildOfClass("Humanoid")
        local hrp = targetChar:FindFirstChild("HumanoidRootPart") or targetChar.PrimaryPart

        -- Model Attributes
        log("--- Character Attributes ---")
        local cAttrs = targetChar:GetAttributes()
        local cAttrKeys = {}
        for k in pairs(cAttrs) do table.insert(cAttrKeys, k) end
        table.sort(cAttrKeys)
        if #cAttrKeys == 0 then
            log("  (none)")
        else
            for _, k in ipairs(cAttrKeys) do
                log(string.format("  %s = %s [%s]", k, safeValStr(cAttrs[k]), typeof(cAttrs[k])))
            end
        end

        -- CollectionService Tags
        local cTags = CollectionService:GetTags(targetChar)
        if #cTags > 0 then
            log("  Tags: " .. table.concat(cTags, ", "))
        end
        log("")

        -- Humanoid Properties & States
        log("--- Humanoid Properties ---")
        if hum then
            log("  RigType:        " .. tostring(hum.RigType))
            log("  Health:         " .. tostring(hum.Health) .. " / " .. tostring(hum.MaxHealth))
            log("  WalkSpeed:      " .. tostring(hum.WalkSpeed))
            log("  JumpPower:      " .. tostring(hum.JumpPower))
            log("  JumpHeight:     " .. tostring(hum.JumpHeight))
            log("  HipHeight:      " .. tostring(hum.HipHeight))
            log("  FloorMaterial:  " .. tostring(hum.FloorMaterial))
            log("  Sit:            " .. tostring(hum.Sit))
            log("  PlatformStand:  " .. tostring(hum.PlatformStand))
            log("  MoveDirection:  " .. safeValStr(hum.MoveDirection))
            pcall(function() log("  HumanoidState:  " .. tostring(hum:GetState())) end)

            -- Animator & Playing Tracks
            local animator = hum:FindFirstChildOfClass("Animator")
            if animator then
                local tracks = animator:GetPlayingAnimationTracks()
                log(string.format("  Playing Animations (%d):", #tracks))
                for _, trk in ipairs(tracks) do
                    local animId = trk.Animation and trk.Animation.AnimationId or "unknown"
                    log(string.format("    - %s [Speed: %.2f, Weight: %.2f, Id: %s]", trk.Name, trk.Speed, trk.WeightCurrent, animId))
                end
            end
        else
            log("  (No Humanoid found in character)")
        end
        log("")

        -- Character Body Parts
        log("--- Character Parts & Geometry ---")
        local parts = {}
        for _, p in ipairs(targetChar:GetChildren()) do
            if p:IsA("BasePart") then table.insert(parts, p) end
        end
        log(string.format("  BaseParts Count: %d", #parts))
        for _, p in ipairs(parts) do
            log(string.format("    - [%s] %s | Size: (%.1f, %.1f, %.1f) | CanCollide: %s | Massless: %s | Mat: %s | Trans: %.2f",
                p.ClassName, p.Name, p.Size.X, p.Size.Y, p.Size.Z, tostring(p.CanCollide), tostring(p.Massless), tostring(p.Material.Name), p.Transparency))
        end
        log("")

        -- Accessories
        log("--- Accessories & Attachments ---")
        local accessories = {}
        for _, a in ipairs(targetChar:GetChildren()) do
            if a:IsA("Accessory") then table.insert(accessories, a) end
        end
        log(string.format("  Accessories Count: %d", #accessories))
        for _, acc in ipairs(accessories) do
            local accType = acc.AccessoryType and tostring(acc.AccessoryType) or "Unknown"
            local handle = acc:FindFirstChild("Handle")
            local handleSize = handle and string.format("(%.1f, %.1f, %.1f)", handle.Size.X, handle.Size.Y, handle.Size.Z) or "no handle"
            log(string.format("    - %s [%s] | Handle: %s", acc.Name, accType, handleSize))
        end
        log("")

        -- Welds, Constraints & External Connections
        log("--- Welds & External Connections ---")
        local externalWelds = {}
        local internalWeldsCount = 0
        for _, d in ipairs(targetChar:GetDescendants()) do
            if d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Motor6D") or d:IsA("Constraint") then
                local p0 = d:IsA("Constraint") and (d.Attachment0 and d.Attachment0.Parent) or d.Part0
                local p1 = d:IsA("Constraint") and (d.Attachment1 and d.Attachment1.Parent) or d.Part1
                if p0 and p1 then
                    local p0In = p0:IsDescendantOf(targetChar)
                    local p1In = p1:IsDescendantOf(targetChar)
                    if (p0In and not p1In) or (p1In and not p0In) then
                        local ext = p0In and p1 or p0
                        table.insert(externalWelds, string.format("    - [%s] %s -> Connected to EXTERNAL object: %s", d.ClassName, d.Name, ext:GetFullName()))
                    else
                        internalWeldsCount = internalWeldsCount + 1
                    end
                end
            end
        end
        log(string.format("  Internal Joint Count: %d", internalWeldsCount))
        if #externalWelds > 0 then
            log(string.format("  External Connections (%d detected):", #externalWelds))
            for _, wStr in ipairs(externalWelds) do log(wStr) end
        else
            log("  External Connections: None (Character is not welded to external objects)")
        end
        log("")
    end

    -- ----------------------------------------------------
    -- 3. HELD TOOL & CARRIED EGG DETECTION
    -- ----------------------------------------------------
    progress("Scanning for held tools and carried eggs...")
    log("===== 3. HELD TOOL & CARRIED EGG DETECTION =====")
    local heldTools = {}
    local carryCandidates = {}

    if targetChar then
        -- 1. Tools equipped in character
        for _, c in ipairs(targetChar:GetChildren()) do
            if c:IsA("Tool") then
                table.insert(heldTools, c)
            end
        end

        log(string.format("Equipped Tools in Character (%d):", #heldTools))
        if #heldTools == 0 then
            log("  (No Tool currently equipped in hand)")
        else
            for _, t in ipairs(heldTools) do
                local tAttrs = t:GetAttributes()
                local dName = tostring(tAttrs.DisplayName or t.Name)
                local cat = tostring(tAttrs.Category or "")
                local itemType = tostring(tAttrs.ItemType or "")
                local uid = tostring(tAttrs.UID or tAttrs.Uid or tAttrs.EggUID or "")
                local isEgg = dName:lower():find("egg") or cat:lower() == "egg" or itemType == "Egg" or tAttrs.IsEgg == true
                local eggTag = isEgg and " [🥚 ACTIVE EGG]" or ""
                log(string.format("  - Tool: %s%s (ItemType: %s, Category: %s, UID: %s)", dName, eggTag, itemType, cat, uid))
                for ak, av in pairs(tAttrs) do
                    log(string.format("      attr: %s = %s", ak, safeValStr(av)))
                end
            end
        end
        log("")

        -- 2. Child models or parts acting as carried eggs
        for _, c in ipairs(targetChar:GetChildren()) do
            if not c:IsA("Tool") and (c:IsA("Model") or c:IsA("BasePart")) then
                local nm = c.Name:lower()
                local cAttrs = c:GetAttributes()
                local isEggCandidate = nm:find("egg") or cAttrs.CarrierUserId ~= nil or cAttrs.CarrierPlayer ~= nil or cAttrs.Uid ~= nil or cAttrs.UID ~= nil
                if isEggCandidate then
                    table.insert(carryCandidates, c)
                end
            end
        end

        if #carryCandidates > 0 then
            log(string.format("Carried Egg Candidates attached to Character (%d):", #carryCandidates))
            for _, obj in ipairs(carryCandidates) do
                log(string.format("  - [%s] %s", obj.ClassName, obj.Name))
                for ak, av in pairs(obj:GetAttributes()) do
                    log(string.format("      attr: %s = %s", ak, safeValStr(av)))
                end
            end
            log("")
        end
    end

    -- 3. Check world eggs where CarrierUserId == targetPlr.UserId
    if targetPlr then
        local carriedFieldEggs = {}
        local eggsFolder = Workspace:FindFirstChild("Eggs") or Workspace:FindFirstChild("WorldEggs")
        local function scanFolderForCarrier(folder)
            if not folder then return end
            for _, e in ipairs(folder:GetChildren()) do
                local attrs = e:GetAttributes()
                local cId = attrs.CarrierUserId
                if cId and (cId == targetPlr.UserId or tostring(cId) == tostring(targetPlr.UserId)) then
                    table.insert(carriedFieldEggs, e)
                end
            end
        end
        scanFolderForCarrier(Workspace:FindFirstChild("Eggs"))
        scanFolderForCarrier(Workspace:FindFirstChild("WorldEggs"))
        scanFolderForCarrier(Workspace:FindFirstChild("Debris"))

        if #carriedFieldEggs > 0 then
            log(string.format("Field Eggs with CarrierUserId == %d (%d):", targetPlr.UserId, #carriedFieldEggs))
            for _, egg in ipairs(carriedFieldEggs) do
                local attrs = egg:GetAttributes()
                local dName = attrs.DisplayName or attrs.AssetCategory or egg.Name
                local uid = attrs.Uid or attrs.UID or attrs.EggUID or "none"
                log(string.format("  - %s (UID: %s, State: %s)", tostring(dName), tostring(uid), tostring(attrs.State)))
            end
            log("")
        end
    end

    -- ----------------------------------------------------
    -- 4. BASE PLOT & PLACED EGGS
    -- ----------------------------------------------------
    progress("Inspecting Base Plot & Placed Egg Renders...")
    log("===== 4. BASE PLOT & PLACED EGGS =====")
    local targetPlot = nil
    local plotsFolder = Workspace:FindFirstChild("Plots") or Workspace:FindFirstChild("Bases")

    if plotsFolder and (targetPlr or targetChar) then
        for _, plot in ipairs(plotsFolder:GetChildren()) do
            local pAttrs = plot:GetAttributes()
            local ownerAttr = pAttrs.Owner or pAttrs.OwnerId or pAttrs.Player or pAttrs.UserId or pAttrs.ClaimedBy
            local isOwner = false
            if targetPlr then
                if ownerAttr == targetPlr.Name or ownerAttr == targetPlr.UserId or tostring(ownerAttr) == tostring(targetPlr.UserId) then
                    isOwner = true
                end
            end
            if not isOwner and plot.Name:lower():find(targetQuery:lower()) then
                isOwner = true
            end
            if isOwner then
                targetPlot = plot
                break
            end
        end
    end

    if targetPlot then
        log("Target Base Plot Found: " .. targetPlot:GetFullName())
        local plotPos = (targetPlot:IsA("Model") and targetPlot.PrimaryPart and targetPlot.PrimaryPart.Position) or (targetPlot:IsA("BasePart") and targetPlot.Position)
        if plotPos then
            log(string.format("  Plot Center: (%.2f, %.2f, %.2f)", plotPos.X, plotPos.Y, plotPos.Z))
            if myPos then
                log(string.format("  Distance from Runner: %.2f studs", (plotPos - myPos).Magnitude))
            end
        end
        log("  Plot Attributes:")
        for ak, av in pairs(targetPlot:GetAttributes()) do
            log(string.format("    %s = %s", ak, safeValStr(av)))
        end
    else
        log("  No explicit plot found in Workspace.Plots for target.")
    end
    log("")

    -- PlacedEggRenders for target UserId
    local placedRenders = Workspace:FindFirstChild("PlacedEggRenders")
    local targetPlacedEggs = {}
    if placedRenders and targetPlr then
        local userPrefix = tostring(targetPlr.UserId) .. "_"
        for _, ch in ipairs(placedRenders:GetChildren()) do
            if string.find(ch.Name, userPrefix, 1, true) then
                local eggUid = ch.Name:sub(#userPrefix + 1)
                table.insert(targetPlacedEggs, {
                    Instance = ch,
                    Name = ch.Name,
                    ClassName = ch.ClassName,
                    EggUid = eggUid
                })
            end
        end
    end

    log(string.format("Eggs Placed in Base Plot (Workspace.PlacedEggRenders) [%d]:", #targetPlacedEggs))
    if #targetPlacedEggs == 0 then
        log("  (None detected or target has no eggs placed on base nests)")
    else
        for idx, item in ipairs(targetPlacedEggs) do
            local ch = item.Instance
            local childModels = {}
            for _, sub in ipairs(ch:GetChildren()) do
                table.insert(childModels, sub.Name)
            end
            local childStr = #childModels > 0 and (" | Models: " .. table.concat(childModels, ", ")) or ""
            log(string.format("  [%d] EggUID: %s (RenderNode: %s)%s", idx, item.EggUid, ch.Name, childStr))
        end
    end
    log("")

    -- ----------------------------------------------------
    -- 5. FOLLOWER PETS & WORKSPACE ENTITIES
    -- ----------------------------------------------------
    progress("Searching Workspace for follower pets...")
    log("===== 5. FOLLOWER PETS & ASSOCIATED WORKSPACE ENTITIES =====")
    local targetPets = {}

    local function checkPetEntity(obj, context)
        if obj == targetChar or obj == myChar then return end
        local ownerAttr = obj:GetAttribute("Owner") or obj:GetAttribute("Player") or obj:GetAttribute("UserId") or obj:GetAttribute("PlayerId")
        local isOwnerMatch = false
        if targetPlr then
            isOwnerMatch = (ownerAttr == targetPlr.Name) or (ownerAttr == targetPlr.UserId) or (tostring(ownerAttr) == tostring(targetPlr.UserId))
        end
        local nameMatch = targetPlr and string.find(obj.Name:lower(), targetPlr.Name:lower())

        -- Proximity match to target character (within 25 studs)
        local isNearby = false
        local targetHrp = targetChar and (targetChar:FindFirstChild("HumanoidRootPart") or targetChar.PrimaryPart)
        if targetHrp and (obj:IsA("Model") or obj:IsA("BasePart")) then
            local primary = (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart"))) or obj
            if primary and primary:IsA("BasePart") then
                local dist = (primary.Position - targetHrp.Position).Magnitude
                if dist <= 25 then
                    isNearby = true
                end
            end
        end

        local hasPetAttr = obj:GetAttribute("Species") ~= nil or obj:GetAttribute("PetName") ~= nil or obj:GetAttribute("PetId") ~= nil or obj:GetAttribute("Uid") ~= nil

        if isOwnerMatch or (hasPetAttr and isNearby) or (nameMatch and isNearby) then
            table.insert(targetPets, {
                Name = obj.Name,
                FullName = obj:GetFullName(),
                ClassName = obj.ClassName,
                Context = context,
                Owner = tostring(ownerAttr),
                Attributes = obj:GetAttributes()
            })
        end
    end

    local candidateContainers = {
        Workspace:FindFirstChild("Pets"),
        Workspace:FindFirstChild("PlayerPets"),
        Workspace:FindFirstChild("Entities"),
        Workspace:FindFirstChild("Characters"),
        Workspace:FindFirstChild("Followers"),
        Workspace:FindFirstChild("Debris"),
        Workspace
    }

    for _, c in ipairs(candidateContainers) do
        if c then
            for _, obj in ipairs(c:GetChildren()) do
                if obj:IsA("Model") or obj:IsA("Folder") then
                    checkPetEntity(obj, c.Name)
                end
            end
        end
    end

    log(string.format("Follower Pets & Entities Detected in Workspace (%d):", #targetPets))
    if #targetPets == 0 then
        log("  No active follower pet models detected in Workspace for target.")
    else
        for idx, pInfo in ipairs(targetPets) do
            local attrs = pInfo.Attributes
            local sp = attrs.Species or attrs.PetName or attrs.Name or pInfo.Name
            local rar = attrs.Rarity or "Unknown"
            local earn = attrs.Earn or attrs.Rate or "0"
            local wt = attrs.Weight or attrs.Kg or "0"
            log(string.format("  [%d] %s [Species: %s, Rarity: %s, Weight: %s, Earn: %s]", idx, pInfo.Name, tostring(sp), tostring(rar), tostring(wt), tostring(earn)))
            log("      FullName: " .. pInfo.FullName)
            for ak, av in pairs(attrs) do
                if ak ~= "Species" and ak ~= "Rarity" and ak ~= "Weight" and ak ~= "Earn" then
                    log(string.format("      attr: %s = %s", ak, safeValStr(av)))
                end
            end
        end
    end
    log("")

    -- ----------------------------------------------------
    -- 6. SERVER REMOTE PROBING (READ-ONLY)
    -- ----------------------------------------------------
    progress("Testing read-only remote queries on target...")
    log("===== 6. SERVER REMOTE TARGETED PROBING (Read-Only) =====")

    if targetPlr then
        -- 1. RF/ProfileMirror/FetchProfile with target player arguments
        local rfProfile = getNetRemote("RF/ProfileMirror/FetchProfile")
        if rfProfile then
            local testArgs = {
                { "targetPlr", { targetPlr } },
                { "targetPlr.UserId", { targetPlr.UserId } },
                { "str_targetUserId", { tostring(targetPlr.UserId) } }
            }
            log("--- RF/ProfileMirror/FetchProfile Targeted Query Tests ---")
            local gotProfile = false
            for _, t in ipairs(testArgs) do
                local ok, res = pcall(function() return rfProfile:InvokeServer(unpack(t[2])) end)
                if ok and type(res) == "table" then
                    local count = 0
                    for _ in pairs(res) do count = count + 1 end
                    log(string.format("  InvokeServer(%s): SUCCESS! Returned table with %d entries", t[1], count))
                    if not gotProfile then
                        gotProfile = true
                        -- Preview keys
                        local keys = {}
                        for k in pairs(res) do table.insert(keys, tostring(k)) end
                        table.sort(keys)
                        log("    Profile Keys: " .. table.concat(keys, ", "))
                    end
                else
                    log(string.format("  InvokeServer(%s): Returned %s", t[1], safeValStr(res)))
                end
            end
        else
            log("  RF/ProfileMirror/FetchProfile not found.")
        end
        log("")

        -- 2. RF/PenRoster/AskLiveSnapshot
        local rfSnapshot = getNetRemote("RF/PenRoster/AskLiveSnapshot")
        if rfSnapshot then
            log("--- RF/PenRoster/AskLiveSnapshot Targeted Query Test ---")
            local ok, snap = pcall(function() return rfSnapshot:InvokeServer(targetPlr.UserId) end)
            if ok and type(snap) == "table" then
                local count = 0
                for _ in pairs(snap) do count = count + 1 end
                log(string.format("  AskLiveSnapshot(UserId): SUCCESS (%d entries)", count))
                log(dumpTable(snap, 2, "    "))
            else
                log(string.format("  AskLiveSnapshot(UserId): %s (Return: %s)", tostring(ok), safeValStr(snap)))
            end
        end
        log("")
    else
        log("  Target player is not in game.Players; skipping remote player invocation.")
        log("")
    end

    -- ----------------------------------------------------
    -- 7. EXECUTIVE TARGET SUMMARY
    -- ----------------------------------------------------
    progress("Compiling executive summary...")
    log("==================================================")
    log("7. EXECUTIVE TARGET SUMMARY")
    log("==================================================")
    log("• Target Query:            " .. targetQuery)
    log("• Resolved Player:         " .. (targetPlr and string.format("%s (@%s) [UserId: %d]", targetPlr.DisplayName, targetPlr.Name, targetPlr.UserId) or "NOT IN PLAYERS LIST"))
    log("• Character Spawned:       " .. (targetChar and "YES (" .. targetChar:GetFullName() .. ")" or "NO"))
    if targetChar and targetChar:FindFirstChild("HumanoidRootPart") and myPos then
        local p = targetChar.HumanoidRootPart.Position
        log(string.format("• Current Position:        (%.1f, %.1f, %.1f) [%.1f studs away]", p.X, p.Y, p.Z, (p - myPos).Magnitude))
    end
    log("• Held / Equipped Tools:   " .. tostring(#heldTools))
    log("• Placed Eggs in Base:     " .. tostring(#targetPlacedEggs))
    log("• Follower Pets Detected:  " .. tostring(#targetPets))
    if targetPlot then
        log("• Base Plot:               " .. targetPlot.Name)
    else
        log("• Base Plot:               Not identified")
    end

    if targetPlr and targetPlr:FindFirstChild("leaderstats") then
        local lsSummary = {}
        for _, s in ipairs(targetPlr.leaderstats:GetChildren()) do
            if s:IsA("ValueBase") then table.insert(lsSummary, string.format("%s: %s", s.Name, tostring(s.Value))) end
        end
        log("• Leaderstats:             " .. table.concat(lsSummary, " | "))
    end

    log("==================================================")
    log("SCAN COMPLETE")
    log("==================================================")

    return table.concat(out, "\n")
end

-- ============================================================
-- UI BUILDER (Clean Draggable Window with Target Selector)
-- ============================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TargetedCharacterScannerGui"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 99999
screenGui.Parent = uiParent

local W, H = 580, 560
local main = Instance.new("Frame")
main.Size = UDim2.new(0, W, 0, H)
main.Position = UDim2.new(0.5, -W/2, 0.5, -H/2)
main.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(60, 110, 200)
mainStroke.Thickness = 1.5

-- Top Bar
local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 38)
topBar.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
topBar.BorderSizePixel = 0
topBar.Parent = main
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -50, 1, 0)
titleLbl.Position = UDim2.new(0, 12, 0, 0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "🎯 TARGETED CHARACTER SCANNER"
titleLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 13
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = topBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -34, 0, 5)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.Parent = topBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
closeBtn.MouseButton1Click:Connect(function()
    screenGui:Destroy()
end)

-- Draggable Logic
do
    local dragging, dragInput, dragStart, startPos
    topBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    topBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- ============================================================
-- TARGET CONTROL BAR (Row 1: Target Input + Scan Button)
-- ============================================================
local ROW1_Y = 44
local targetLabel = Instance.new("TextLabel")
targetLabel.Size = UDim2.new(0, 54, 0, 28)
targetLabel.Position = UDim2.new(0, 12, 0, ROW1_Y)
targetLabel.BackgroundTransparency = 1
targetLabel.Text = "Target:"
targetLabel.TextColor3 = Color3.fromRGB(180, 210, 255)
targetLabel.Font = Enum.Font.GothamBold
targetLabel.TextSize = 12
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.Parent = main

local targetInput = Instance.new("TextBox")
targetInput.Size = UDim2.new(0, 240, 0, 28)
targetInput.Position = UDim2.new(0, 68, 0, ROW1_Y)
targetInput.BackgroundColor3 = Color3.fromRGB(25, 30, 42)
targetInput.Text = "Kaihii"
targetInput.PlaceholderText = "Enter character or player name..."
targetInput.TextColor3 = Color3.fromRGB(255, 230, 120)
targetInput.Font = Enum.Font.GothamBold
targetInput.TextSize = 12
targetInput.ClearTextOnFocus = false
targetInput.Parent = main
Instance.new("UICorner", targetInput).CornerRadius = UDim.new(0, 6)
local tiStroke = Instance.new("UIStroke", targetInput)
tiStroke.Color = Color3.fromRGB(60, 90, 140)
tiStroke.Thickness = 1

local scanBtn = Instance.new("TextButton")
scanBtn.Size = UDim2.new(0, 130, 0, 28)
scanBtn.Position = UDim2.new(0, 316, 0, ROW1_Y)
scanBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
scanBtn.Text = "▶ SCAN TARGET"
scanBtn.TextColor3 = Color3.new(1, 1, 1)
scanBtn.Font = Enum.Font.GothamBold
scanBtn.TextSize = 12
scanBtn.Parent = main
Instance.new("UICorner", scanBtn).CornerRadius = UDim.new(0, 6)

-- Quick Switch Chip for Self
local selfBtn = Instance.new("TextButton")
selfBtn.Size = UDim2.new(0, 110, 0, 28)
selfBtn.Position = UDim2.new(0, 454, 0, ROW1_Y)
selfBtn.BackgroundColor3 = Color3.fromRGB(45, 52, 68)
selfBtn.Text = "Me (" .. LocalPlayer.Name:sub(1, 8) .. ")"
selfBtn.TextColor3 = Color3.fromRGB(180, 210, 240)
selfBtn.Font = Enum.Font.Gotham
selfBtn.TextSize = 11
selfBtn.Parent = main
Instance.new("UICorner", selfBtn).CornerRadius = UDim.new(0, 6)
selfBtn.MouseButton1Click:Connect(function()
    targetInput.Text = LocalPlayer.Name
end)

-- ============================================================
-- QUICK-SELECT PLAYER CHIPS (Row 2)
-- ============================================================
local ROW2_Y = 78
local chipsScroll = Instance.new("ScrollingFrame")
chipsScroll.Size = UDim2.new(1, -24, 0, 26)
chipsScroll.Position = UDim2.new(0, 12, 0, ROW2_Y)
chipsScroll.BackgroundTransparency = 1
chipsScroll.BorderSizePixel = 0
chipsScroll.ScrollBarThickness = 2
chipsScroll.ScrollBarImageColor3 = Color3.fromRGB(70, 110, 170)
chipsScroll.ScrollingDirection = Enum.ScrollingDirection.X
chipsScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
chipsScroll.Parent = main

local chipsLayout = Instance.new("UIListLayout")
chipsLayout.FillDirection = Enum.FillDirection.Horizontal
chipsLayout.Padding = UDim.new(0, 6)
chipsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
chipsLayout.Parent = chipsScroll

local function populatePlayerChips()
    for _, ch in ipairs(chipsScroll:GetChildren()) do
        if ch:IsA("TextButton") then ch:Destroy() end
    end

    local players = Players:GetPlayers()
    for _, p in ipairs(players) do
        local chip = Instance.new("TextButton")
        local isKaihii = (p.Name:lower():find("kaihii") or p.DisplayName:lower():find("kaihii"))
        chip.Size = UDim2.new(0, 0, 0, 22)
        chip.AutomaticSize = Enum.AutomaticSize.X
        chip.BackgroundColor3 = isKaihii and Color3.fromRGB(90, 70, 20) or Color3.fromRGB(32, 38, 52)
        chip.Text = string.format(" %s (@%s) ", p.DisplayName, p.Name)
        chip.TextColor3 = isKaihii and Color3.fromRGB(255, 230, 120) or Color3.fromRGB(180, 205, 235)
        chip.Font = isKaihii and Enum.Font.GothamBold or Enum.Font.Gotham
        chip.TextSize = 10
        chip.Parent = chipsScroll
        Instance.new("UICorner", chip).CornerRadius = UDim.new(0, 5)
        local cpStroke = Instance.new("UIStroke", chip)
        cpStroke.Color = isKaihii and Color3.fromRGB(180, 140, 40) or Color3.fromRGB(50, 60, 80)
        cpStroke.Thickness = 1

        chip.MouseButton1Click:Connect(function()
            targetInput.Text = p.Name
        end)
    end
end
pcall(populatePlayerChips)

-- ============================================================
-- ACTION BUTTONS ROW (Row 3: Copy, Save, Clear)
-- ============================================================
local ROW3_Y = 110
local BTN_H = 26
local BTN_W = 110
local GAP = 8

local copyBtn = Instance.new("TextButton")
copyBtn.Size = UDim2.new(0, BTN_W, 0, BTN_H)
copyBtn.Position = UDim2.new(0, 12, 0, ROW3_Y)
copyBtn.BackgroundColor3 = Color3.fromRGB(45, 95, 160)
copyBtn.Text = "📋 COPY"
copyBtn.TextColor3 = Color3.new(1, 1, 1)
copyBtn.Font = Enum.Font.GothamBold
copyBtn.TextSize = 11
copyBtn.Parent = main
Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 6)

local saveBtn = Instance.new("TextButton")
saveBtn.Size = UDim2.new(0, BTN_W, 0, BTN_H)
saveBtn.Position = UDim2.new(0, 12 + (BTN_W + GAP), 0, ROW3_Y)
saveBtn.BackgroundColor3 = Color3.fromRGB(90, 60, 140)
saveBtn.Text = "💾 SAVE FILE"
saveBtn.TextColor3 = Color3.new(1, 1, 1)
saveBtn.Font = Enum.Font.GothamBold
saveBtn.TextSize = 11
saveBtn.Parent = main
Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 6)

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0, 90, 0, BTN_H)
clearBtn.Position = UDim2.new(0, 12 + (BTN_W + GAP)*2, 0, ROW3_Y)
clearBtn.BackgroundColor3 = Color3.fromRGB(50, 56, 72)
clearBtn.Text = "CLEAR"
clearBtn.TextColor3 = Color3.fromRGB(200, 210, 230)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 11
clearBtn.Parent = main
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 6)

-- Status Indicator
local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -24, 0, 18)
statusLabel.Position = UDim2.new(0, 12, 0, ROW3_Y + BTN_H + 6)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Status: Ready to scan target 'Kaihii'"
statusLabel.TextColor3 = Color3.fromRGB(150, 190, 240)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = main

-- ============================================================
-- SCROLLABLE OUTPUT VIEWER
-- ============================================================
local BOX_Y = ROW3_Y + BTN_H + 28
local BOX_H = H - BOX_Y - 12

local scrollFrame = Instance.new("ScrollingFrame")
scrollFrame.Size = UDim2.new(1, -24, 0, BOX_H)
scrollFrame.Position = UDim2.new(0, 12, 0, BOX_Y)
scrollFrame.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
scrollFrame.BorderSizePixel = 0
scrollFrame.ScrollBarThickness = 6
scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(60, 110, 200)
scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
scrollFrame.Parent = main
Instance.new("UICorner", scrollFrame).CornerRadius = UDim.new(0, 8)
local boxStroke = Instance.new("UIStroke", scrollFrame)
boxStroke.Color = Color3.fromRGB(38, 48, 68)
boxStroke.Thickness = 1

local textBox = Instance.new("TextBox")
textBox.Size = UDim2.new(1, -16, 0, 0)
textBox.Position = UDim2.new(0, 8, 0, 8)
textBox.AutomaticSize = Enum.AutomaticSize.Y
textBox.BackgroundTransparency = 1
textBox.MultiLine = true
textBox.ClearTextOnFocus = false
textBox.TextEditable = false
textBox.TextXAlignment = Enum.TextXAlignment.Left
textBox.TextYAlignment = Enum.TextYAlignment.Top
textBox.Font = Enum.Font.Code
textBox.TextSize = 10
textBox.TextColor3 = Color3.fromRGB(180, 230, 200)
textBox.Text = "-- Targeted Character Scanner Ready --\n-- Target: Kaihii\n-- Click [SCAN TARGET] to inspect."
textBox.Parent = scrollFrame

local cachedOutput = ""

local function performScan()
    local targetName = targetInput.Text
    if targetName == "" then targetName = "Kaihii" end

    scanBtn.Text = "⏳ SCANNING..."
    scanBtn.BackgroundColor3 = Color3.fromRGB(100, 100, 40)
    statusLabel.Text = "Status: Scanning target '" .. targetName .. "' in progress..."
    statusLabel.TextColor3 = Color3.fromRGB(255, 230, 100)

    task.defer(function()
        local ok, result = pcall(function()
            return runTargetedScan(targetName, function(stage)
                statusLabel.Text = "Status: " .. stage
            end)
        end)

        if ok and result then
            cachedOutput = result
            textBox.Text = result

            local clipOk = false
            if typeof(setclipboard) == "function" then
                clipOk = pcall(setclipboard, result)
            end

            statusLabel.Text = clipOk and ("Status: Scan complete for '" .. targetName .. "'! Copied to clipboard.") or ("Status: Scan complete for '" .. targetName .. "'! Ready to copy/save.")
            statusLabel.TextColor3 = Color3.fromRGB(120, 255, 160)
            print(string.format("[Targeted Scanner] Completed for '%s'. Output length: %d", targetName, #result))
        else
            statusLabel.Text = "Status: Scan failed: " .. tostring(result)
            statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
            warn("[Targeted Scanner] Error: " .. tostring(result))
        end

        scanBtn.Text = "▶ SCAN TARGET"
        scanBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
    end)
end

scanBtn.MouseButton1Click:Connect(performScan)
targetInput.FocusLost:Connect(function(enterPressed)
    if enterPressed then performScan() end
end)

copyBtn.MouseButton1Click:Connect(function()
    if cachedOutput == "" then
        statusLabel.Text = "Status: No output to copy. Run scan first."
        statusLabel.TextColor3 = Color3.fromRGB(255, 160, 100)
        return
    end
    local clipOk = false
    if typeof(setclipboard) == "function" then
        clipOk = pcall(setclipboard, cachedOutput)
    end
    if clipOk then
        statusLabel.Text = "Status: Copied " .. tostring(#cachedOutput) .. " chars to clipboard!"
        statusLabel.TextColor3 = Color3.fromRGB(120, 255, 160)
    else
        textBox.TextEditable = true
        textBox:CaptureFocus()
        statusLabel.Text = "Status: setclipboard unavailable. Text focused for manual Ctrl+C."
        statusLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    if cachedOutput == "" then
        statusLabel.Text = "Status: No output to save. Run scan first."
        statusLabel.TextColor3 = Color3.fromRGB(255, 160, 100)
        return
    end
    local cleanName = targetInput.Text:gsub("%W+", "_"):lower()
    if cleanName == "" then cleanName = "target" end
    local fileName = string.format("targeted-%s-scan.log", cleanName)

    if typeof(writefile) == "function" then
        local ok, err = pcall(writefile, fileName, cachedOutput)
        if ok then
            statusLabel.Text = "Status: Saved to " .. fileName .. "!"
            statusLabel.TextColor3 = Color3.fromRGB(120, 255, 160)
        else
            statusLabel.Text = "Status: writefile failed: " .. tostring(err)
            statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        end
    else
        statusLabel.Text = "Status: writefile() not supported in this executor."
        statusLabel.TextColor3 = Color3.fromRGB(255, 180, 100)
    end
end)

clearBtn.MouseButton1Click:Connect(function()
    cachedOutput = ""
    textBox.Text = "-- Cleared --"
    statusLabel.Text = "Status: Cleared."
    statusLabel.TextColor3 = Color3.fromRGB(180, 190, 210)
end)

-- Re-populate player chips if players join/leave
pcall(function()
    Players.PlayerAdded:Connect(function() pcall(populatePlayerChips) end)
    Players.PlayerRemoving:Connect(function() pcall(populatePlayerChips) end)
end)

-- Auto-trigger scan for Kaihii on launch
task.defer(performScan)

print("[Targeted Character Scanner] Initialized. Target: Kaihii.")
