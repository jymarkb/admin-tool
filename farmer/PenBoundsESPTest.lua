-- ================================================================================
-- PEN BOUNDARIES & 4-SIDE ESP INSPECTOR (STANDALONE TEST TOOL)
-- ================================================================================
-- Purpose:
--   Accurately detects the location and physical boundaries (width, length, height)
--   of the player's Pen / Nests, and renders distinct 3D ESP markers for:
--     1. FRONT Side (+Z / South) -> Cyan
--     2. BACK Side  (-Z / North) -> Orange
--     3. LEFT Side  (-X / West)  -> Green
--     4. RIGHT Side (+X / East)  -> Yellow
--     5. CENTER Beacon & Floor   -> White / Translucent Blue
--     6. 4 CORNER Pillars        -> Purple
--
-- Features:
--   - Real-time BillboardGuis showing side names, dimensions, and live player distance.
--   - Interactive walk-to tests: "Walk to Center", "Walk to Front/Back/Left/Right".
--   - Manual boundary tuning: +/- Width and Length sliders.
--   - Plot hierarchy inspection: dumps all parts inside your plot to console.
-- ================================================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then return end

-- Configuration & State
local SAFE_ZONE_FALLBACK = Vector3.new(6575.43, 69.96, -438.45)

local State = {
    EspActive = true,
    ShowSlotGrid = true,
    DetectedSource = "None",
    CenterMode = "Auto", -- "Auto", "PenModel", "PlotPivot", "CenterPoint"
    SizeMode = "FullPen", -- "FullPen", "Compact18"
    SideOrientation = "Auto", -- "Auto", "Flipped"
    MyPlot = nil,
    MyPlotIndex = nil,
    PenCenter = nil,
    PenSize = Vector3.new(50, 8, 113),
    PenCFrame = nil,
    PlacedEggs = {},
    MaxEggs = nil,
    MaxEggsSource = "Unknown",
    MaxEggsDetails = {},
    EspContainer = nil,
    Labels = {},
    SlotAdornments = {},
    UpdateConnection = nil,
    NavThread = nil,
}

local logEntries = {}
local logCallback = nil

local function logMsg(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    local timestamp = os.date("%H:%M:%S")
    local formatted = string.format("[%s] [PenESP] %s", timestamp, msg)
    table.insert(logEntries, formatted)
    if #logEntries > 500 then
        table.remove(logEntries, 1)
    end
    print(formatted)
    if logCallback then
        pcall(logCallback, formatted)
    end
end

-- ================================================================================
-- 1. DETECTION ENGINE: PLOT, PLACED EGGS & PEN BOUNDS
-- ================================================================================
local function distXZ(a, b)
    if not a or not b then return math.huge end
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

local function isRealEggTool(t)
    if not t or not t:IsA("Tool") then return false end
    local attrs = t:GetAttributes()

    -- 1. ABSOLUTE REJECTION: Never match pets (ItemType="Asset"), gear, or consumables!
    if attrs.ItemType == "Asset" then return false end
    if attrs.ItemType == "Gear" or attrs.GearName ~= nil or attrs.IsBat == true then return false end
    if attrs.ItemType == "MutationConsumable" or attrs.MutationId ~= nil then return false end
    if attrs.ItemType == "ButterflyNet" or attrs.ButterflyNet == true then return false end

    -- 2. POSITIVE CONFIRMATION: Must be a genuine egg tool
    if attrs.ItemType == "Egg" or attrs.Category == "Egg" then return true end
    if attrs.EggUid ~= nil then return true end
    local lowName = string.lower(t.Name)
    if string.find(lowName, "egg", 1, true) then return true end

    return false
end

local function findMyPlot(forceRefresh)
    if not forceRefresh and State.MyPlot and State.MyPlot.Parent then
        return State.MyPlot, State.MyPlotIndex
    end

    local plotsFolder = Workspace:FindFirstChild("Plots") or Workspace:FindFirstChild("Bases")
    if not plotsFolder then return nil, nil end

    local myId = LocalPlayer.UserId
    local myIdStr = tostring(myId)
    local myName  = string.lower(LocalPlayer.Name or "")
    local myDispName = LocalPlayer.DisplayName and string.lower(LocalPlayer.DisplayName) or ""

    -- Tier 0: Server Authoritative via RF/Homestead/AskState
    pcall(function()
        local rfHome = getNetRemote("RF/Homestead/AskState")
        if rfHome then
            local ok, res = pcall(function() return rfHome:InvokeServer() end)
            if ok and type(res) == "table" and type(res.OwnersBySlot) == "table" then
                for slotKey, ownerId in pairs(res.OwnersBySlot) do
                    if tonumber(ownerId) == myId or tostring(ownerId) == myIdStr then
                        local slotNum = tonumber(slotKey) or tonumber(string.match(tostring(slotKey), "%d+"))
                        local plot = plotsFolder:FindFirstChild(tostring(slotKey))
                            or (slotNum and plotsFolder:FindFirstChild(tostring(slotNum)))
                        if not plot then
                            for _, ch in ipairs(plotsFolder:GetChildren()) do
                                if ch.Name == tostring(slotKey) or (slotNum and (tonumber(ch.Name) == slotNum or tonumber(string.match(ch.Name, "%d+")) == slotNum)) then
                                    plot = ch
                                    break
                                end
                            end
                        end
                        if plot then
                            State.MyPlot = plot
                            State.MyPlotIndex = slotNum
                            return
                        end
                    end
                end
            end
        end
    end)
    if State.MyPlot and State.MyPlot.Parent then
        return State.MyPlot, State.MyPlotIndex
    end

    -- Tier 1: PlacedEggRenders Anchor (<UserId>_*)
    local placedRenders = Workspace:FindFirstChild("PlacedEggRenders")
    if placedRenders then
        local myPrefix = myIdStr .. "_"
        local myEggs = {}
        for _, egg in ipairs(placedRenders:GetChildren()) do
            if string.find(egg.Name, myPrefix, 1, true) then
                local p = nil
                if egg:IsA("BasePart") then p = egg.Position
                elseif egg:IsA("Model") then
                    local ok, piv = pcall(function() return egg:GetPivot().Position end)
                    p = ok and piv or (egg.PrimaryPart and egg.PrimaryPart.Position)
                end
                if p then table.insert(myEggs, p) end
            end
        end
        if #myEggs > 0 then
            local bestPlot, bestDist, bestIdx = nil, math.huge, nil
            for _, plot in ipairs(plotsFolder:GetChildren()) do
                local pPos = nil
                if plot:IsA("Model") then
                    local ok, piv = pcall(function() return plot:GetPivot().Position end)
                    pPos = ok and piv or (plot.PrimaryPart and plot.PrimaryPart.Position)
                elseif plot:IsA("BasePart") then
                    pPos = plot.Position
                end
                if pPos then
                    local totalD = 0
                    for _, ePos in ipairs(myEggs) do totalD = totalD + distXZ(pPos, ePos) end
                    local avgD = totalD / #myEggs
                    if avgD < bestDist then
                        bestDist = avgD
                        bestPlot = plot
                        bestIdx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                    end
                end
            end
            if bestPlot and bestDist <= 120 then
                State.MyPlot = bestPlot
                State.MyPlotIndex = bestIdx
                return bestPlot, bestIdx
            end
        end
    end

    -- Pass 1: Authoritative Owner attribute check
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local pAttrs = plot:GetAttributes()
        local ownerAttr = pAttrs.Owner or pAttrs.OwnerId or pAttrs.Player or pAttrs.UserId or pAttrs.ClaimedBy
        if ownerAttr then
            local strOwner = tostring(ownerAttr):lower()
            if strOwner == myIdStr or strOwner == myName or (myDispName ~= "" and strOwner == myDispName) then
                local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                State.MyPlot = plot
                State.MyPlotIndex = idx
                return plot, idx
            end
        end
    end

    -- Pass 2: Sign text check
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        for _, desc in ipairs(plot:GetDescendants()) do
            if desc:IsA("TextLabel") or desc:IsA("SurfaceGui") then
                local txt = desc:IsA("TextLabel") and desc.Text:lower() or ""
                if (myName ~= "" and string.find(txt, myName, 1, true)) or (myDispName ~= "" and string.find(txt, myDispName, 1, true)) then
                    local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                    State.MyPlot = plot
                    State.MyPlotIndex = idx
                    return plot, idx
                end
            end
        end
    end

    -- Pass 3: Proximity to SAFE_ZONE
    local bestPlot, bestDist = nil, math.huge
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local pPos = nil
        if plot:IsA("Model") then
            local ok, piv = pcall(function() return plot:GetPivot().Position end)
            pPos = ok and piv or (plot.PrimaryPart and plot.PrimaryPart.Position)
        elseif plot:IsA("BasePart") then
            pPos = plot.Position
        end
        if pPos then
            local d = distXZ(pPos, SAFE_ZONE_FALLBACK)
            if d < bestDist then
                bestDist = d
                bestPlot = plot
            end
        end
    end

    if bestPlot and bestDist <= 80 then
        local idx = tonumber(bestPlot.Name) or tonumber(string.match(bestPlot.Name, "%d+"))
        State.MyPlot = bestPlot
        State.MyPlotIndex = idx
        return bestPlot, idx
    end

    return nil, nil
end

local function scanPlacedEggs()
    local list = {}
    local placedRenders = Workspace:FindFirstChild("PlacedEggRenders")
    if placedRenders then
        local myPrefix = tostring(LocalPlayer.UserId) .. "_"
        for _, egg in ipairs(placedRenders:GetChildren()) do
            if string.find(egg.Name, myPrefix, 1, true) then
                local p = nil
                if egg:IsA("BasePart") then
                    p = egg.Position
                elseif egg:IsA("Model") then
                    local ok, piv = pcall(function() return egg:GetPivot().Position end)
                    p = ok and piv or (egg.PrimaryPart and egg.PrimaryPart.Position)
                end
                if p then
                    table.insert(list, { Inst = egg, Pos = p })
                end
            end
        end
    end
    State.PlacedEggs = list
    return list
end

-- ================================================================================
-- 1.5 PEN EGG CAPACITY & LIMIT PROBE ENGINE
-- ================================================================================
local function getNetRemote(name)
    local pkg = ReplicatedStorage:FindFirstChild("Packages")
    local net = pkg and pkg:FindFirstChild("Networking")
    if net then
        local r = net:FindFirstChild(name)
        if r then return r end
    end
    return ReplicatedStorage:FindFirstChild(name, true)
end

local function getSpatialCapacity(size)
    if not size then return 16, 4, 4 end
    -- Clamp effective pen dimensions to realistic egg pen bounds (max 22 studs)
    local effX = math.min(size.X, 22.0)
    local effZ = math.min(size.Z, 22.0)
    local slotSize = 3.5 -- Standard physical egg footprint + spacing in studs
    local cols = math.max(1, math.floor(effX / slotSize))
    local rows = math.max(1, math.floor(effZ / slotSize))
    local rawFit = cols * rows
    -- Hard clamp spatial packing to realistic game maximum (<= 30 eggs)
    local sCap = math.min(rawFit, 30)
    return sCap, cols, rows
end

local function probePenCapacity()
    local findings = {}
    local detectedMax = nil
    local detectedSource = nil

    -- Recursive table inspector to extract capacity values and log all keys
    local function inspectTableForCap(prefix, tbl, depth)
        depth = depth or 1
        if type(tbl) ~= "table" or depth > 3 then return end
        for k, v in pairs(tbl) do
            local fullKey = prefix .. "." .. tostring(k)
            local kLow = tostring(k):lower()
            if type(v) == "table" then
                table.insert(findings, string.format("  %s = [table]", fullKey))
                inspectTableForCap(fullKey, v, depth + 1)
            else
                table.insert(findings, string.format("  %s = %s", fullKey, tostring(v)))
                if tonumber(v) then
                    local num = tonumber(v)
                    if num > 0 and num <= 100 then
                        if kLow:find("cap") or kLow:find("max") or kLow:find("limit") or kLow:find("slot") or kLow:find("count") or kLow:find("tier") then
                            if not detectedMax or kLow:find("cap") or kLow:find("max") then
                                detectedMax = num
                                detectedSource = fullKey
                            end
                        end
                    end
                end
            end
        end
    end

    -- 1. Query RF/Homestead/AskState (Homestead Base Tier & Attributes)
    pcall(function()
        local rfHome = getNetRemote("RF/Homestead/AskState")
        if rfHome then
            local ok, res = pcall(function() return rfHome:InvokeServer() end)
            if ok and type(res) == "table" then
                table.insert(findings, "✓ RF/Homestead/AskState: returned table")
                inspectTableForCap("Homestead", res, 1)
            else
                table.insert(findings, "• RF/Homestead/AskState: " .. tostring(res))
            end
        else
            table.insert(findings, "• RF/Homestead/AskState: not found")
        end
    end)

    -- 2. Query RF/ProfileMirror/FetchProfile (Authoritative Player Profile Data)
    pcall(function()
        local rfProf = getNetRemote("RF/ProfileMirror/FetchProfile")
        if rfProf then
            local prof = nil
            for attempt = 1, 3 do
                local ok, res = pcall(function() return rfProf:InvokeServer(LocalPlayer) end)
                if ok and type(res) == "table" then
                    prof = res
                    break
                end
                task.wait(0.2)
            end
            if not prof then
                local ok, res = pcall(function() return rfProf:InvokeServer() end)
                if ok and type(res) == "table" then prof = res end
            end

            if prof and type(prof) == "table" then
                table.insert(findings, "✓ RF/ProfileMirror/FetchProfile: returned data")

                -- 2a. Priority Deep Inspection: PetPenCapacityGuidance
                if prof.PetPenCapacityGuidance and type(prof.PetPenCapacityGuidance) == "table" then
                    table.insert(findings, "⭐ Deep Inspecting Profile.PetPenCapacityGuidance:")
                    inspectTableForCap("Profile.PetPenCapacityGuidance", prof.PetPenCapacityGuidance, 1)
                end

                -- 2b. General profile keys inspection
                for k, v in pairs(prof) do
                    local strK = tostring(k):lower()
                    if strK:find("pen") or strK:find("eggcap") or strK:find("maxegg") or strK:find("homestead") or strK:find("basetier") then
                        if k ~= "PetPenCapacityGuidance" then
                            if type(v) == "table" then
                                table.insert(findings, string.format("  Profile.%s = [table]", tostring(k)))
                                inspectTableForCap("Profile." .. tostring(k), v, 2)
                            else
                                table.insert(findings, string.format("  Profile.%s = %s", tostring(k), tostring(v)))
                                if tonumber(v) and (strK:find("max") or strK:find("cap") or strK:find("limit")) then
                                    local num = tonumber(v)
                                    if num > 0 and num <= 100 and not detectedMax then
                                        detectedMax = num
                                        detectedSource = "Profile." .. tostring(k)
                                    end
                                end
                            end
                        end
                    end
                end
            else
                table.insert(findings, "• RF/ProfileMirror/FetchProfile: " .. tostring(prof))
            end
        end
    end)

    -- 3. Query RF/EggWorld/AskLiveSnapshot
    pcall(function()
        local rfSnap = getNetRemote("RF/EggWorld/AskLiveSnapshot")
        if rfSnap then
            local ok, snap = pcall(function() return rfSnap:InvokeServer() end)
            if ok and type(snap) == "table" then
                local sKeys = {}
                for k in pairs(snap) do table.insert(sKeys, tostring(k)) end
                table.insert(findings, string.format("✓ RF/EggWorld/AskLiveSnapshot: keys [%s]", table.concat(sKeys, ", ")))
                for k, v in pairs(snap) do
                    local strK = tostring(k):lower()
                    if strK:find("cap") or strK:find("limit") or strK:find("max") or strK:find("pen") or strK:find("egg") then
                        table.insert(findings, string.format("  EggWorld.%s = %s", tostring(k), tostring(v)))
                        if tonumber(v) and not detectedMax then
                            detectedMax = tonumber(v)
                            detectedSource = "EggWorld." .. tostring(k)
                        end
                    end
                end
            end
        end
    end)

    -- 4. Live PlayerGui Pattern Scanner (In-game UI Counters e.g. "3/5 Eggs")
    pcall(function()
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        if pg then
            for _, d in ipairs(pg:GetDescendants()) do
                if d:IsA("TextLabel") and d.Visible and d.Text ~= "" then
                    local txt = d.Text
                    local cur, mx = string.match(txt, "(%d+)%s*/%s*(%d+)%s*[Ee]gg")
                    if not mx then
                        cur, mx = string.match(txt, "[Ee]ggs?:?%s*(%d+)%s*/%s*(%d+)")
                    end
                    if not mx then
                        cur, mx = string.match(txt, "[Pp]en:?%s*(%d+)%s*/%s*(%d+)")
                    end
                    if not mx then
                        cur, mx = string.match(txt, "[Cc]apacity:?%s*(%d+)%s*/%s*(%d+)")
                    end
                    if not mx then
                        cur, mx = string.match(txt, "[Ii]ncubat%w*:?%s*(%d+)%s*/%s*(%d+)")
                    end
                    if mx and tonumber(mx) then
                        local n = tonumber(mx)
                        if n > 0 and n <= 100 then
                            table.insert(findings, string.format("✓ PlayerGui Counter: %q in %s", txt, d.Name))
                            if not detectedMax then
                                detectedMax = n
                                detectedSource = string.format("PlayerGui (%s)", d.Name)
                            end
                        end
                    end
                end
            end
        end
    end)

    -- 5. Plot Attributes, Hierarchy & Surface Signs
    local plot = State.MyPlot or findMyPlot()
    if plot then
        pcall(function()
            local pAttrs = plot:GetAttributes()
            for k, v in pairs(pAttrs) do
                local strK = tostring(k):lower()
                if strK:find("egg") or strK:find("cap") or strK:find("limit") or strK:find("tier") then
                    table.insert(findings, string.format("✓ Plot Attr: %s = %s", tostring(k), tostring(v)))
                    if tonumber(v) and not detectedMax then
                        detectedMax = tonumber(v)
                        detectedSource = "PlotAttr." .. tostring(k)
                    end
                end
            end
        end)

        -- Detailed child inspection inside Plot and StarterPen / ToUpdate
        pcall(function()
            for _, ch in ipairs(plot:GetChildren()) do
                local pStr = ""
                local szStr = ""
                if ch:IsA("BasePart") then
                    pStr = string.format("Pos:(%.1f, %.1f, %.1f)", ch.Position.X, ch.Position.Y, ch.Position.Z)
                    szStr = string.format("Sz:(%.1f, %.1f, %.1f)", ch.Size.X, ch.Size.Y, ch.Size.Z)
                elseif ch:IsA("Model") then
                    local ok, cfM, s = pcall(function() return ch:GetBoundingBox() end)
                    if ok and cfM and s then
                        pStr = string.format("Pos:(%.1f, %.1f, %.1f)", cfM.Position.X, cfM.Position.Y, cfM.Position.Z)
                        szStr = string.format("BBox:(%.1f, %.1f, %.1f)", s.X, s.Y, s.Z)
                    end
                end
                table.insert(findings, string.format("  Plot Child: %s [%s] %s %s", ch.Name, ch.ClassName, pStr, szStr))

                if ch.Name == "StarterPen" or ch.Name == "ToUpdate" or ch.Name:lower():find("pen") or ch.Name:lower():find("update") then
                    for _, sub in ipairs(ch:GetChildren()) do
                        local subP = ""
                        local subSz = ""
                        if sub:IsA("BasePart") then
                            subP = string.format("Pos:(%.1f, %.1f, %.1f)", sub.Position.X, sub.Position.Y, sub.Position.Z)
                            subSz = string.format("Sz:(%.1f, %.1f, %.1f)", sub.Size.X, sub.Size.Y, sub.Size.Z)
                        elseif sub:IsA("Model") then
                            local ok, cfSub, s = pcall(function() return sub:GetBoundingBox() end)
                            if ok and cfSub and s then
                                subP = string.format("Pos:(%.1f, %.1f, %.1f)", cfSub.Position.X, cfSub.Position.Y, cfSub.Position.Z)
                                subSz = string.format("BBox:(%.1f, %.1f, %.1f)", s.X, s.Y, s.Z)
                            end
                        end
                        table.insert(findings, string.format("    %s.%s [%s] %s %s", ch.Name, sub.Name, sub.ClassName, subP, subSz))
                    end
                end
            end
        end)
    end

    -- 6. Geometric Spatial Packing Capacity (Hard clamped to <= 30)
    local sCap, sCols, sRows = getSpatialCapacity(State.PenSize)
    table.insert(findings, string.format("• Spatial Packing Fit: %d eggs (%d cols x %d rows @ 3.5 studs, max clamped to 30)", sCap, sCols, sRows))

    if not detectedMax then
        detectedMax = sCap
        detectedSource = string.format("Spatial Grid (%d max)", sCap)
    end

    State.MaxEggs = detectedMax
    State.MaxEggsSource = detectedSource
    State.MaxEggsDetails = findings

    logMsg("Capacity Probe: MaxEggs=%s (Source: %s)", tostring(detectedMax), tostring(detectedSource))
    for _, line in ipairs(findings) do
        logMsg("  %s", line)
    end

    return detectedMax, detectedSource, findings
end

-- ================================================================================
-- BAG SCANNER & GROUPING INSPECTOR (EGG TYPES & RARITIES)
-- ================================================================================
local RARITY_RANK = {
    ["Divine"]    = 10,
    ["Eternal"]   = 9,
    ["Secret"]    = 8,
    ["Cosmic"]    = 7,
    ["Mythic"]    = 6,
    ["Legendary"] = 5,
    ["Epic"]      = 4,
    ["Rare"]      = 3,
    ["Uncommon"]  = 2,
    ["Common"]    = 1,
    ["Unknown"]   = 0,
}

local PET_RARITY_PRESETS = {
    -- Divine
    ["ArchAngel"]="Divine", ["World Burner"]="Divine", ["Archdemon Dragon"]="Divine",
    ["Unicorn"]="Divine", ["Kitsune"]="Divine", ["Nightflame"]="Divine", ["Godzilla"]="Divine",
    ["Nuclear Mantis"]="Divine", ["Cthulhu"]="Divine", ["Luminous Cthulhu"]="Divine",
    ["Shattered Colossus"]="Divine", ["Dreadscale"]="Divine", ["Mecha Dreadscale"]="Divine",
    ["Depths Riptide Octopus"]="Divine", ["Aetheron"]="Divine", ["Octophant"]="Divine",

    -- Eternal
    ["Eternal Lunar Dragon"]="Eternal", ["Skeleton Horse"]="Eternal", ["Pegasus"]="Eternal",
    ["Oni Tiger"]="Eternal", ["King Kong"]="Eternal", ["Gorilla King"]="Eternal",
    ["Mosasaurus"]="Eternal", ["Ice Dragon"]="Eternal", ["El Maja"]="Eternal",
    ["Riptide Octopus"]="Eternal", ["Phoenix"]="Eternal", ["Ascended Vermilion Phoenix"]="Eternal",
    ["Lava Dragon"]="Eternal", ["Dragon"]="Eternal", ["Nuceodille"]="Eternal",
    ["Void Dragon"]="Eternal", ["Shattered Drake"]="Eternal", ["Void Serpent"]="Eternal",
    ["World Eater"]="Eternal", ["Strawberry Elephant"]="Eternal", ["Krakenoid"]="Eternal",
    ["Mecha Krakenoid"]="Eternal", ["Terra Snapper"]="Eternal", ["Luminous Terra Snapper"]="Eternal",
    ["Balrog"]="Eternal", ["Equinox"]="Eternal",

    -- Secret
    ["Alien Skeleton Boss"]="Secret", ["Cosmic Skeleton Boss"]="Secret",
    ["Cave Dragon"]="Secret", ["Cosmic Dragon"]="Secret",
    ["Cosmic Fox"]="Secret", ["Dark Gargoyle"]="Secret", ["Gargoyle"]="Secret",
    ["Centaur"]="Secret", ["Jellyfish"]="Secret", ["Pure Jellyfish"]="Secret",
    ["RazorFang"]="Secret", ["Stag"]="Secret", ["TyrannosaurusRex"]="Secret",
    ["TRex"]="Secret", ["Tralaledon"]="Secret", ["Yeti"]="Secret",
    ["Mutant Shark"]="Secret", ["Kraken"]="Secret", ["Biohazard"]="Secret",
    ["Biohazard Egg"]="Secret", ["Experiment Egg"]="Secret",
    ["Cerberus"]="Secret", ["King Snake"]="Secret", ["Warden"]="Secret",
    ["Bomboclat Crocolat"]="Secret", ["Crocodon"]="Secret", ["Mecha Crocodon"]="Secret",
    ["Electric Eel"]="Secret", ["Luminous Electric Eel"]="Secret", ["Abyss Overlord"]="Secret",
    ["Ember Dragon"]="Secret", ["Experiment #001"]="Secret", ["Mawbreaker"]="Secret",
    ["Shardwing"]="Secret", ["Wendigo"]="Secret", ["Ringlord"]="Secret",

    -- Cosmic
    ["Cosmic Lion"]="Cosmic", ["La Vacca Saturno Saturnita"]="Cosmic", ["Mantis"]="Cosmic",
    ["Drilla"]="Cosmic", ["Imp"]="Cosmic", ["Demon Hound"]="Cosmic", ["Moth"]="Cosmic",
    ["Sacred Moth"]="Cosmic", ["Peacock"]="Cosmic", ["Holy Peacock"]="Cosmic",
    ["Spirit Panda"]="Cosmic", ["Spirit Hare"]="Cosmic", ["Koi"]="Cosmic",
    ["Snowy Owl"]="Cosmic", ["Rhino"]="Cosmic", ["Rhinotaur"]="Cosmic",
    ["Triceratops"]="Cosmic", ["Bronto"]="Cosmic", ["King Mammoth"]="Cosmic",
    ["Colossal Mammoth"]="Cosmic", ["Whale Shark"]="Cosmic", ["Beluga Whale"]="Cosmic",
    ["Royal Sphinx"]="Cosmic", ["Irihorus"]="Cosmic", ["Crawler"]="Cosmic",
    ["Mecha Crawler"]="Cosmic", ["Abyss Shark"]="Cosmic", ["Luminous Abyss Shark"]="Cosmic",
    ["Leviathan"]="Cosmic", ["Basilisk"]="Cosmic", ["Nibbles #013"]="Cosmic",
    ["Dreadclaw"]="Cosmic", ["Shattered Ram"]="Cosmic", ["Ventinal"]="Cosmic",
    ["Mangolini Parrochini"]="Cosmic", ["Radcoon"]="Cosmic", ["Spiderpig"]="Cosmic",
    ["Three Headed Chicken"]="Cosmic", ["Stacked Turtle"]="Cosmic",

    -- Mythic
    ["Cyclops Gorilla"]="Mythic", ["Cosmic Gorilla"]="Mythic", ["Cosmic Beetle Blue"]="Mythic",
    ["Lamb"]="Mythic", ["Winged Lamb"]="Mythic", ["Toro"]="Mythic", ["Toucax"]="Mythic",
    ["Red Panda"]="Mythic", ["Enchanted Bluejay"]="Mythic", ["Blade Head"]="Mythic",
    ["Rhinobear"]="Mythic", ["Ankylosaurus"]="Mythic", ["Mammoth"]="Mythic",
    ["Sabertooth Tiger"]="Mythic", ["Orca"]="Mythic", ["Sand Spider"]="Mythic",
    ["Scorpion"]="Mythic", ["DeathstalkerScorpion"]="Mythic", ["Chillin Chilli"]="Mythic",
    ["Froggo"]="Mythic", ["Mecha Froggo"]="Mythic", ["Spirit Manta"]="Mythic",
    ["Luminous Spirit Manta"]="Mythic", ["Belula Beluga"]="Mythic", ["Shadow Dragon"]="Mythic",
    ["Riftwing"]="Mythic", ["Shardling"]="Mythic", ["Voidmaw"]="Mythic", ["Tiger"]="Mythic",
    ["Spider"]="Mythic", ["Toxic Rat"]="Mythic", ["Wheel Hamster"]="Mythic",
    ["Frogfly"]="Mythic",

    -- Legendary
    ["Galaxy Gecko"]="Legendary", ["Cosmic Gecko"]="Legendary", ["Flame Sprite"]="Legendary",
    ["Salamander"]="Legendary", ["Kaiju Spider"]="Legendary", ["Crab"]="Legendary",
    ["Sharkodile"]="Legendary", ["Pterodactyl"]="Legendary", ["Polar Bear"]="Legendary",
    ["Shark"]="Legendary", ["Finned Thresher"]="Legendary", ["Snake"]="Legendary",
    ["Rattlesnake"]="Legendary", ["Hellhound"]="Legendary", ["Lava Iguana"]="Legendary",
    ["Flaming Bull"]="Legendary", ["Scorpio"]="Legendary", ["Mecha Scorpio"]="Legendary",
    ["Spike"]="Legendary", ["Luminous Spike"]="Legendary", ["Baby Aurora Dragon"]="Legendary",
    ["Rift Eye"]="Legendary", ["Void Angler"]="Legendary", ["Dove"]="Legendary",
    ["Brr Brr Patapim"]="Legendary", ["Axolotl"]="Legendary", ["Dream Axolotl"]="Legendary",
    ["Gorilla"]="Legendary", ["Prism Gecko"]="Legendary",

    -- Epic
    ["Centapede"]="Epic", ["Crane"]="Epic", ["Walrus"]="Epic", ["Swordfish"]="Epic",
    ["Toxic Crocodile"]="Epic", ["Tob Tobi Tob Tob"]="Epic", ["Uncoiled Armadillo"]="Epic",
    ["Lava Frog"]="Epic", ["Citadel Snail"]="Epic", ["Ash Gecko"]="Epic",
    ["Bananita Dolphinita"]="Epic", ["Trulimero Trulicina"]="Epic", ["Swan"]="Epic",
    ["Fox"]="Epic", ["Bear"]="Epic", ["Crocodile"]="Epic",

    -- Rare
    ["Dodo"]="Rare", ["Penguin"]="Rare", ["Parrotfish"]="Rare", ["Toxic Hedgehog"]="Rare",
    ["Camel"]="Rare", ["DesertLark"]="Rare", ["Lava Gecko"]="Rare", ["Tung Tung Sahur"]="Rare",
    ["Burrowing Owl"]="Rare", ["Owl"]="Rare", ["Raccoon"]="Rare", ["Turtle"]="Rare",
    ["Toucan"]="Rare", ["Chimpanzee"]="Rare",

    -- Uncommon
    ["Catfish"]="Uncommon", ["Bird"]="Uncommon", ["Fennec"]="Uncommon", ["FennecFox"]="Uncommon",

    -- Common
    ["Chicken"]="Common", ["Dog"]="Common", ["Frog"]="Common", ["Duckling"]="Common",
    ["Jerboa"]="Common",
}

local EGG_NAME_TO_DEFAULT_RARITY = {
    ["biohazard"]              = "Secret",
    ["biohazard egg"]          = "Secret",
    ["experiment"]             = "Secret",
    ["experiment egg"]         = "Secret",
    ["angels & demons"]        = "Divine",
    ["angels & demons egg"]    = "Divine",
    ["titan temple"]           = "Divine",
    ["titan temple egg"]       = "Divine",
    ["cosmic"]                 = "Cosmic",
    ["cosmic egg"]             = "Cosmic",
    ["enchanted forest"]       = "Legendary",
    ["enchanted forest egg"]   = "Legendary",
    ["lava"]                   = "Legendary",
    ["lava egg"]               = "Legendary",
    ["snow"]                   = "Rare",
    ["snow egg"]               = "Rare",
    ["prehistoric"]            = "Rare",
    ["prehistoric egg"]        = "Rare",
    ["cherry blossom"]         = "Rare",
    ["cherry blossom egg"]     = "Rare",
    ["ocean"]                  = "Rare",
    ["ocean egg"]              = "Rare",
    ["depths"]                 = "Divine",
    ["depths egg"]             = "Divine",
    ["unstable"]               = "Common",
    ["unstable egg"]           = "Common",
    ["egg"]                    = "Common",
}

local KNOWN_BIOME_EGGS = {
    "Angels & Demons Egg",
    "Titan Temple Egg",
    "Cosmic Egg",
    "Prehistoric Egg",
    "Enchanted Forest Egg",
    "Snow Egg",
    "Biohazard Egg",
    "Cherry Blossom Egg",
    "Ocean Egg",
    "Depths Egg",
    "Desert Egg",
    "Lava Egg",
    "Unstable Egg",
    "Riftborn Egg",
    "Monster Egg",
    "Dragon Egg",
    "Luminous Egg",
    "Egg",
}

local STATIC_SPECIES_TO_BIOME_EGG = {
    -- Cosmic Egg
    ["Alien Skeleton Boss"] = "Cosmic Egg",
    ["Cosmic Skeleton Boss"] = "Cosmic Egg",
    ["Cave Dragon"] = "Cosmic Egg",
    ["Cosmic Dragon"] = "Cosmic Egg",
    ["Cosmic Fox"] = "Cosmic Egg",
    ["Starry Fox"] = "Cosmic Egg",
    ["Cosmic Lion"] = "Cosmic Egg",
    ["Cyclops Gorilla"] = "Cosmic Egg",
    ["Cosmic Gorilla"] = "Cosmic Egg",
    ["Eternal Lunar Dragon"] = "Cosmic Egg",
    ["Galaxy Gecko"] = "Cosmic Egg",
    ["Cosmic Gecko"] = "Cosmic Egg",
    ["La Vacca Saturno Saturnita"] = "Cosmic Egg",
    ["Mantis"] = "Cosmic Egg",
    ["Cosmic Beetle Blue"] = "Cosmic Egg",
    ["Drilla"] = "Cosmic Egg",

    -- Angels & Demons Egg
    ["Dark Gargoyle"] = "Angels & Demons Egg", ["Gargoyle"] = "Angels & Demons Egg",
    ["Centaur"] = "Angels & Demons Egg",
    ["Jellyfish"] = "Angels & Demons Egg", ["Pure Jellyfish"] = "Angels & Demons Egg",
    ["Skeleton Horse"] = "Angels & Demons Egg", ["Pegasus"] = "Angels & Demons Egg",
    ["ArchAngel"] = "Angels & Demons Egg", ["World Burner"] = "Angels & Demons Egg",
    ["RazorFang"] = "Angels & Demons Egg", ["Imp"] = "Angels & Demons Egg",
    ["Demon Hound"] = "Angels & Demons Egg", ["Flame Sprite"] = "Angels & Demons Egg",
    ["Toro"] = "Angels & Demons Egg", ["Archdemon Dragon"] = "Angels & Demons Egg",
    ["Lamb"] = "Angels & Demons Egg", ["Winged Lamb"] = "Angels & Demons Egg",
    ["Moth"] = "Angels & Demons Egg", ["Sacred Moth"] = "Angels & Demons Egg",
    ["Peacock"] = "Angels & Demons Egg", ["Holy Peacock"] = "Angels & Demons Egg",

    -- Enchanted Forest Egg
    ["Spirit Panda"] = "Enchanted Forest Egg", ["Spirit Hare"] = "Enchanted Forest Egg",
    ["Toucax"] = "Enchanted Forest Egg", ["Red Panda"] = "Enchanted Forest Egg",
    ["Enchanted Bluejay"] = "Enchanted Forest Egg", ["Salamander"] = "Enchanted Forest Egg",
    ["Stag"] = "Enchanted Forest Egg", ["Centapede"] = "Enchanted Forest Egg",
    ["Unicorn"] = "Enchanted Forest Egg", ["Kitsune"] = "Enchanted Forest Egg",
    ["Koi"] = "Enchanted Forest Egg", ["Snowy Owl"] = "Enchanted Forest Egg",
    ["Crane"] = "Enchanted Forest Egg", ["Oni Tiger"] = "Enchanted Forest Egg",

    -- Titan Temple Egg
    ["King Kong"] = "Titan Temple Egg", ["Gorilla King"] = "Titan Temple Egg",
    ["Kaiju Spider"] = "Titan Temple Egg", ["Godzilla"] = "Titan Temple Egg",
    ["Nightflame"] = "Titan Temple Egg", ["Blade Head"] = "Titan Temple Egg",
    ["Crab"] = "Titan Temple Egg", ["Rhino"] = "Titan Temple Egg",
    ["Rhinobear"] = "Titan Temple Egg", ["Rhinotaur"] = "Titan Temple Egg",

    -- Prehistoric Egg
    ["Mosasaurus"] = "Prehistoric Egg", ["TyrannosaurusRex"] = "Prehistoric Egg",
    ["TRex"] = "Prehistoric Egg", ["Tralaledon"] = "Prehistoric Egg",
    ["Triceratops"] = "Prehistoric Egg", ["Bronto"] = "Prehistoric Egg",
    ["Ankylosaurus"] = "Prehistoric Egg", ["Pterodactyl"] = "Prehistoric Egg",
    ["Dodo"] = "Prehistoric Egg",

    -- Snow Egg
    ["Ice Dragon"] = "Snow Egg", ["Yeti"] = "Snow Egg",
    ["King Mammoth"] = "Snow Egg", ["Mammoth"] = "Snow Egg",
    ["Colossal Mammoth"] = "Snow Egg", ["Sabertooth Tiger"] = "Snow Egg",
    ["Polar Bear"] = "Snow Egg", ["Walrus"] = "Snow Egg",
    ["Penguin"] = "Snow Egg",

    -- Ocean Egg / Depths Egg
    ["Whale Shark"] = "Ocean Egg", ["Shark"] = "Ocean Egg",
    ["Mutant Shark"] = "Ocean Egg", ["Finned Thresher"] = "Ocean Egg",
    ["Beluga Whale"] = "Ocean Egg", ["Orca"] = "Ocean Egg",
    ["Kraken"] = "Ocean Egg", ["El Maja"] = "Ocean Egg",
    ["Swordfish"] = "Ocean Egg", ["Parrotfish"] = "Ocean Egg",
    ["Stacked Turtle"] = "Ocean Egg", ["Octophant"] = "Ocean Egg",
    ["Abyss Overlord"] = "Depths Egg", ["Riptide Octopus"] = "Ocean Egg",

    -- Biohazard Egg
    ["Biohazard"] = "Biohazard Egg", ["Toxic Rat"] = "Biohazard Egg",
    ["Radcoon"] = "Biohazard Egg", ["Toxic Crocodile"] = "Biohazard Egg",
    ["Toxic Hedgehog"] = "Biohazard Egg", ["Nuclear Mantis"] = "Biohazard Egg",
    ["Nuceodille"] = "Biohazard Egg",

    -- Desert Egg
    ["Royal Sphinx"] = "Desert Egg", ["Irihorus"] = "Desert Egg",
    ["Sand Spider"] = "Desert Egg", ["Scorpion"] = "Desert Egg",
    ["DeathstalkerScorpion"] = "Desert Egg", ["Snake"] = "Desert Egg",
    ["Rattlesnake"] = "Desert Egg", ["Tob Tobi Tob Tob"] = "Desert Egg",
    ["Camel"] = "Desert Egg", ["Fennec"] = "Desert Egg",
    ["FennecFox"] = "Desert Egg", ["Jerboa"] = "Desert Egg",
    ["DesertLark"] = "Desert Egg",

    -- Lava Egg
    ["Phoenix"] = "Lava Egg", ["Ascended Vermilion Phoenix"] = "Lava Egg",
    ["Lava Dragon"] = "Lava Egg", ["Dragon"] = "Lava Egg",
    ["Cerberus"] = "Lava Egg", ["Chillin Chilli"] = "Lava Egg",
    ["Lava Iguana"] = "Lava Egg", ["Flaming Bull"] = "Lava Egg",
    ["Lava Frog"] = "Lava Egg", ["Lava Gecko"] = "Lava Egg",
    ["Ash Gecko"] = "Lava Egg",

    -- Unstable Egg
    ["Frogfly"] = "Unstable Egg", ["Wheel Hamster"] = "Unstable Egg",
    ["Three Headed Chicken"] = "Unstable Egg", ["Spiderpig"] = "Unstable Egg",

    -- Starter Egg
    ["Chicken"] = "Egg", ["Dog"] = "Egg", ["Frog"] = "Egg",
    ["Duckling"] = "Egg", ["Catfish"] = "Egg", ["Turtle"] = "Egg",
    ["Bird"] = "Egg", ["Owl"] = "Egg", ["Burrowing Owl"] = "Egg",
    ["Raccoon"] = "Egg", ["Fox"] = "Egg", ["Bear"] = "Egg",
    ["Swan"] = "Egg", ["Brr Brr Patapim"] = "Egg", ["Axolotl"] = "Egg",
    ["Dream Axolotl"] = "Egg", ["Toucan"] = "Egg", ["Chimpanzee"] = "Egg",
    ["Crocodile"] = "Egg", ["Gorilla"] = "Egg", ["Tiger"] = "Egg",
    ["Spider"] = "Egg", ["King Snake"] = "Egg", ["Warden"] = "Egg",
}

local speciesToEggMap = {}
local speciesToRarityMap = {}

local function indexSpeciesConfigs()
    pcall(function()
        local confFolder = ReplicatedStorage:FindFirstChild("Data")
            and ReplicatedStorage.Data:FindFirstChild("Assets")
            and ReplicatedStorage.Data.Assets:FindFirstChild("Configs")
        if not confFolder then return end

        for _, mod in ipairs(confFolder:GetChildren()) do
            if mod:IsA("ModuleScript") then
                local ok, data = pcall(require, mod)
                if ok and type(data) == "table" then
                    local eggName = nil
                    if type(data.Egg) == "table" then
                        eggName = data.Egg.DisplayName or data.Egg.Name or data.Egg._id or data.Egg.EggName
                    elseif type(data.Egg) == "string" then
                        eggName = data.Egg
                    end

                    local rarityName = nil
                    if type(data.Rarity) == "table" then
                        rarityName = data.Rarity.DisplayName or data.Rarity.Name or data.Rarity._id
                    elseif type(data.Rarity) == "string" then
                        rarityName = data.Rarity
                    end

                    local mLow = mod.Name:lower()
                    if eggName then
                        speciesToEggMap[mLow] = eggName
                        if data.DisplayName then speciesToEggMap[tostring(data.DisplayName):lower()] = eggName end
                    end
                    if rarityName then
                        speciesToRarityMap[mLow] = rarityName
                        if data.DisplayName then speciesToRarityMap[tostring(data.DisplayName):lower()] = rarityName end
                    end
                end
            end
        end
    end)
end
task.spawn(indexSpeciesConfigs)

local function resolveEggBiomeAndRarity(rawNameOrSpecies, directRarity, uid)
    local raw = tostring(rawNameOrSpecies or ""):gsub("%s*%([%d,%.]+%s*[Kk][Gg]%)%s*$", "")
    raw = raw:gsub("^%s*", ""):gsub("%s*$", "")
    if raw == "" then raw = "Egg" end
    local low = raw:lower()

    local function getRarity(nameKey, fallback)
        if directRarity and directRarity ~= "" and directRarity ~= "Unknown" then
            return directRarity
        end
        local nLow = nameKey and nameKey:lower()
        if nLow and speciesToRarityMap[nLow] then
            return speciesToRarityMap[nLow]
        end
        if nameKey and PET_RARITY_PRESETS[nameKey] then
            return PET_RARITY_PRESETS[nameKey]
        end
        if nLow and EGG_NAME_TO_DEFAULT_RARITY[nLow] then
            return EGG_NAME_TO_DEFAULT_RARITY[nLow]
        end
        local bLow = nLow and nLow:gsub("%s*egg$", "")
        if bLow and EGG_NAME_TO_DEFAULT_RARITY[bLow] then
            return EGG_NAME_TO_DEFAULT_RARITY[bLow]
        end
        return fallback or "Common"
    end

    -- 1. Direct Biome / Event Egg exact match (e.g. "Biohazard Egg", "Angels & Demons Egg")
    for _, bEgg in ipairs(KNOWN_BIOME_EGGS) do
        local bLow = bEgg:lower()
        local bBase = bLow:gsub("%s*egg$", "")
        if low == bLow or low == bBase then
            local rar = getRarity(raw, EGG_NAME_TO_DEFAULT_RARITY[bLow] or EGG_NAME_TO_DEFAULT_RARITY[bBase] or "Common")
            return bEgg, rar, raw
        end
    end

    -- 2. Species exact match from static ground truth (Authoritative Biome Grouping!)
    for sp, eggGroup in pairs(STATIC_SPECIES_TO_BIOME_EGG) do
        if sp:lower() == low then
            local rar = getRarity(sp)
            return eggGroup, rar, sp
        end
    end

    -- 3. Species exact match from dynamic configs
    if speciesToEggMap[low] then
        local bEgg = speciesToEggMap[low]
        local rar = getRarity(raw)
        return bEgg, rar, raw
    end

    -- 4. Direct Biome substring match
    for _, bEgg in ipairs(KNOWN_BIOME_EGGS) do
        local bLow = bEgg:lower()
        local bBase = bLow:gsub("%s*egg$", "")
        if bBase ~= "" and low:find(bBase, 1, true) then
            local rar = getRarity(raw, EGG_NAME_TO_DEFAULT_RARITY[bLow] or EGG_NAME_TO_DEFAULT_RARITY[bBase] or "Common")
            return bEgg, rar, raw
        end
    end

    -- 5. Species substring match (longest keys first to prevent 'Dragon' matching 'Cave Dragon')
    local sortedSpecies = {}
    for sp in pairs(STATIC_SPECIES_TO_BIOME_EGG) do table.insert(sortedSpecies, sp) end
    table.sort(sortedSpecies, function(a, b) return #a > #b end)

    for _, sp in ipairs(sortedSpecies) do
        local sLow = sp:lower()
        if low:find(sLow, 1, true) or sLow:find(low, 1, true) then
            local eggGroup = STATIC_SPECIES_TO_BIOME_EGG[sp]
            local rar = getRarity(sp)
            return eggGroup, rar, sp
        end
    end

    -- 6. Fallback
    local fallback = raw
    if not fallback:lower():find("egg") then
        fallback = fallback .. " Egg"
    end
    local rar = getRarity(raw, "Common")
    return fallback, rar, raw
end

local function dumpBagGrouping()
    logMsg("==================================================")
    logMsg("🎒 CURRENT BAG EGGS GROUPED BY BIOME/EVENT & RARITY")
    logMsg("==================================================")

    local seenUids = {}
    local rawEggList = {}

    -- 1. Scan ProfileMirror (Authoritative unplaced eggs: Placement == nil)
    pcall(function()
        local rfProf = getNetRemote("RF/ProfileMirror/FetchProfile")
        if rfProf then
            local prof = nil
            for attempt = 1, 3 do
                local ok, res = pcall(function() return rfProf:InvokeServer(LocalPlayer) end)
                if ok and type(res) == "table" then prof = res; break end
                task.wait(0.2)
            end
            if not prof then
                local ok, res = pcall(function() return rfProf:InvokeServer() end)
                if ok and type(res) == "table" then prof = res end
            end

            if prof and type(prof.EggInventory) == "table" then
                for eggUid, eggData in pairs(prof.EggInventory) do
                    local uidStr = tostring(eggUid)
                    if type(eggData) == "table" then
                        local isPlaced = (eggData.Placement ~= nil and eggData.Placement ~= false and eggData.Placement ~= "")
                        if not isPlaced and not seenUids[uidStr] then
                            seenUids[uidStr] = true
                            local rawName = eggData.DisplayName or eggData.AssetCategory or "Egg"
                            local biomeEgg, rarity, species = resolveEggBiomeAndRarity(rawName, eggData.Rarity or eggData.RarityId or eggData.Tier, uidStr)
                            local weight = tonumber(eggData.Weight or eggData.Scale or 0)
                            table.insert(rawEggList, {
                                Uid = uidStr,
                                RawName = rawName,
                                GroupName = biomeEgg,
                                Rarity = rarity,
                                Species = species,
                                Weight = weight,
                                Source = "ProfileSatchel",
                            })
                        end
                    end
                end
            end
        end
    end)

    -- 2. Scan Backpack
    pcall(function()
        local bp = LocalPlayer:FindFirstChild("Backpack")
        if bp then
            for _, item in ipairs(bp:GetChildren()) do
                if isRealEggTool(item) then
                    local uid = item:GetAttribute("EggUid") or item:GetAttribute("UID") or item:GetAttribute("Uid") or item.Name
                    local uidStr = tostring(uid)
                    if not seenUids[uidStr] then
                        seenUids[uidStr] = true
                        local rarAttr = item:GetAttribute("Rarity") or item:GetAttribute("RarityId") or item:GetAttribute("Tier")
                        local biomeEgg, rarity, species = resolveEggBiomeAndRarity(item.Name, rarAttr, uidStr)
                        local weight = tonumber(item:GetAttribute("Weight") or 0)
                        table.insert(rawEggList, {
                            Uid = uidStr,
                            RawName = item.Name,
                            GroupName = biomeEgg,
                            Rarity = rarity,
                            Species = species,
                            Weight = weight,
                            Source = "Backpack",
                        })
                    end
                end
            end
        end
    end)

    -- 3. Scan Character
    pcall(function()
        local char = LocalPlayer.Character
        if char then
            for _, item in ipairs(char:GetChildren()) do
                if isRealEggTool(item) then
                    local uid = item:GetAttribute("EggUid") or item:GetAttribute("UID") or item:GetAttribute("Uid") or item.Name
                    local uidStr = tostring(uid)
                    if not seenUids[uidStr] then
                        seenUids[uidStr] = true
                        local rarAttr = item:GetAttribute("Rarity") or item:GetAttribute("RarityId")
                        local biomeEgg, rarity, species = resolveEggBiomeAndRarity(item.Name, rarAttr, uidStr)
                        local weight = tonumber(item:GetAttribute("Weight") or 0)
                        table.insert(rawEggList, {
                            Uid = uidStr,
                            RawName = item.Name,
                            GroupName = biomeEgg,
                            Rarity = rarity,
                            Species = species,
                            Weight = weight,
                            Source = "Equipped",
                        })
                    end
                end
            end
        end
    end)

    -- 4. Build Grouped Table
    local grouped = {}
    for _, egg in ipairs(rawEggList) do
        local g = egg.GroupName
        local r = egg.Rarity
        if not grouped[g] then
            grouped[g] = { GroupName = g, TotalCount = 0, Rarities = {} }
        end
        grouped[g].TotalCount = grouped[g].TotalCount + 1
        if not grouped[g].Rarities[r] then
            grouped[g].Rarities[r] = { Rarity = r, Count = 0, Eggs = {}, SpeciesCounts = {} }
        end
        grouped[g].Rarities[r].Count = grouped[g].Rarities[r].Count + 1
        table.insert(grouped[g].Rarities[r].Eggs, egg)

        local sp = egg.Species or egg.RawName
        if sp then
            grouped[g].Rarities[r].SpeciesCounts[sp] = (grouped[g].Rarities[r].SpeciesCounts[sp] or 0) + 1
        end
    end

    logMsg("Total Unplaced Eggs in Bag: %d", #rawEggList)
    local sortedGroups = {}
    for gName in pairs(grouped) do table.insert(sortedGroups, gName) end
    table.sort(sortedGroups)

    for i, gName in ipairs(sortedGroups) do
        local gData = grouped[gName]
        logMsg("📦 [%d] %s (Total: %d)", i, gName, gData.TotalCount)
        local sortedRars = {}
        for rName in pairs(gData.Rarities) do table.insert(sortedRars, rName) end
        table.sort(sortedRars, function(a, b) return (RARITY_RANK[a] or 0) > (RARITY_RANK[b] or 0) end)
        for _, rName in ipairs(sortedRars) do
            local rData = gData.Rarities[rName]
            local sampleWeights = {}
            for k = 1, math.min(3, #rData.Eggs) do
                local w = rData.Eggs[k].Weight
                if w and w > 0 then table.insert(sampleWeights, string.format("%.0fkg", w)) end
            end
            local wStr = #sampleWeights > 0 and (" | Weights: " .. table.concat(sampleWeights, ", ")) or ""

            local spParts = {}
            if rData.SpeciesCounts then
                for sp, cnt in pairs(rData.SpeciesCounts) do
                    table.insert(spParts, string.format("%s x%d", sp, cnt))
                end
                table.sort(spParts)
            end
            local spStr = #spParts > 0 and (" (" .. table.concat(spParts, ", ") .. ")") or ""

            logMsg("    • [%s] x %d%s%s", rName, rData.Count, spStr, wStr)
        end
    end
    logMsg("==================================================")
end

-- Calculates the 3D bounding box, center, and 4 sides of the pen
local function resolvePenBounds()
    local eggs = scanPlacedEggs()
    local plot, plotIdx = findMyPlot()

    local center = nil
    local size = nil
    local cf = nil
    local source = "Unknown"

    -- Mode Overrides (if user explicitly selected a mode in GUI)
    if State.CenterMode == "PlotPivot" and plot then
        local ok, piv = pcall(function() return plot:GetPivot() end)
        if ok and piv then
            center = piv.Position
            size = Vector3.new(18.0, 3.0, 18.0)
            cf = piv
            source = string.format("Manual Mode: Plot '%s' Pivot", plot.Name)
        end
    elseif State.CenterMode == "CenterPoint" and plot then
        local cp = plot:FindFirstChild("CenterPoint")
        if cp and cp:IsA("BasePart") then
            center = cp.Position
            size = Vector3.new(18.0, 3.0, 18.0)
            cf = cp.CFrame
            source = "Manual Mode: CenterPoint Part"
        end
    elseif State.CenterMode == "PenModel" and plot then
        local penModel = plot:FindFirstChild("ToUpdate") or plot:FindFirstChild("StarterPen")
        if not penModel then
            for _, ch in ipairs(plot:GetChildren()) do
                if ch:IsA("Model") and (ch.Name:lower():find("pen") or ch.Name:lower():find("update")) then
                    penModel = ch
                    break
                end
            end
        end
        if penModel then
            local ok, mCF = pcall(function() return penModel:GetBoundingBox() end)
            if ok and mCF then
                center = mCF.Position
                size = Vector3.new(18.0, 3.0, 18.0)
                cf = mCF
                source = string.format("Manual Mode: Pen Model '%s' Center", penModel.Name)
            end
        end
    end

    -- AUTO STRATEGY PIPELINE (when CenterMode == 'Auto' or override missing)
    -- STRATEGY 1: Placed Eggs Cluster Bounds (Highest Authority & Real Game Coordinates)
    if not center and #eggs > 0 then
        local minX, maxX = math.huge, -math.huge
        local minY, maxY = math.huge, -math.huge
        local minZ, maxZ = math.huge, -math.huge
        for _, e in ipairs(eggs) do
            local p = e.Pos
            if p.X < minX then minX = p.X end
            if p.X > maxX then maxX = p.X end
            if p.Y < minY then minY = p.Y end
            if p.Y > maxY then maxY = p.Y end
            if p.Z < minZ then minZ = p.Z end
            if p.Z > maxZ then maxZ = p.Z end
        end

        local spanX = maxX - minX
        local spanZ = maxZ - minZ
        local avgX = (minX + maxX) / 2
        local avgY = (minY + maxY) / 2
        local avgZ = (minZ + maxZ) / 2

        center = Vector3.new(avgX, avgY, avgZ)
        -- Give natural pen buffer around the eggs (clamped between 14 and 24 studs)
        size = Vector3.new(math.clamp(spanX + 8.0, 14.0, 24.0), 3.0, math.clamp(spanZ + 8.0, 14.0, 24.0))
        cf = CFrame.new(center)
        source = string.format("Placed Eggs Cluster (%d eggs)", #eggs)
    end

    -- STRATEGY 2: Specific Small Pen / Nest Subpart inside Plot (<= 32 studs)
    if not center and plot then
        local penPart = nil
        for _, desc in ipairs(plot:GetDescendants()) do
            local low = string.lower(desc.Name)
            if (low:find("nest") or low:find("incubator") or low:find("eggspot") or low:find("delivery") or low:find("eggzone") or low:find("deposit") or low == "pen" or low:find("penfloor")) then
                if desc:IsA("BasePart") and desc.Size.X >= 2 and desc.Size.Z >= 2 and desc.Size.X <= 32 and desc.Size.Z <= 32 then
                    penPart = desc
                    break
                elseif desc:IsA("Model") and #desc:GetChildren() > 0 then
                    local ok, _, s = pcall(function() return desc:GetBoundingBox() end)
                    if ok and s and s.X <= 32 and s.Z <= 32 then
                        penPart = desc
                        break
                    end
                end
            end
        end

        if penPart then
            if penPart:IsA("BasePart") then
                center = penPart.Position
                size = Vector3.new(math.clamp(penPart.Size.X, 10, 24), math.max(penPart.Size.Y, 2.5), math.clamp(penPart.Size.Z, 10, 24))
                cf = penPart.CFrame
                source = string.format("Plot Part '%s'", penPart.Name)
            elseif penPart:IsA("Model") then
                local mCF, mSize = penPart:GetBoundingBox()
                center = mCF.Position
                size = Vector3.new(math.clamp(mSize.X, 10, 24), math.max(mSize.Y, 2.5), math.clamp(mSize.Z, 10, 24))
                cf = mCF
                source = string.format("Plot Model '%s'", penPart.Name)
            end
        end
    end

    -- STRATEGY 2.5: Pen Compound Model (ToUpdate / StarterPen / PetArea)
    local petArea = (plot and plot:FindFirstChild("ToUpdate") and plot.ToUpdate:FindFirstChild("PetArea"))
        or (plot and plot:FindFirstChild("StarterPen") and plot.StarterPen:FindFirstChild("PetArea"))
        or (plot and plot:FindFirstChild("PetArea", true))

    local penModel = (plot and plot:FindFirstChild("ToUpdate"))
        or (plot and plot:FindFirstChild("StarterPen"))
    if not penModel and plot then
        for _, ch in ipairs(plot:GetChildren()) do
            if ch:IsA("Model") and (ch.Name:lower():find("pen") or ch.Name:lower():find("update")) then
                penModel = ch
                break
            end
        end
    end

    if not center and petArea and petArea:IsA("BasePart") then
        center = Vector3.new(petArea.Position.X, petArea.Position.Y + 2.0, petArea.Position.Z)
        source = string.format("Plot PetArea Part '%s'", petArea.Name)
    elseif not center and penModel then
        local ok, mCF = pcall(function() return penModel:GetBoundingBox() end)
        if ok and mCF then
            center = mCF.Position
            source = string.format("Plot Pen Model '%s' Center", penModel.Name)
        end
    end

    -- STRATEGY 2.6: CenterPoint part inside Plot
    if not center and plot then
        local cp = plot:FindFirstChild("CenterPoint")
        if cp and cp:IsA("BasePart") then
            center = cp.Position
            source = "Plot CenterPoint"
        end
    end

    -- STRATEGY 3: Plot Pivot Fallback
    if not center and plot then
        local ok, piv = pcall(function() return plot:GetPivot() end)
        if ok and piv then
            center = piv.Position
            source = string.format("Plot '%s' Pivot Fallback", plot.Name)
        end
    end

    -- STRATEGY 4: SafeZone Constant fallback
    if not center then
        center = SAFE_ZONE_FALLBACK
        source = "SafeZone Fallback"
    end

    -- Determine Pen Dimensions (Width across plot, Length along plot)
    local fullW = 49.3
    local fullL = 112.7
    local fullH = 8.0

    if petArea and petArea:IsA("BasePart") then
        local d1 = petArea.Size.X
        local d2 = petArea.Size.Z
        fullW = math.min(d1, d2)
        fullL = math.max(d1, d2)
    elseif penModel then
        local ok, _, mSize = pcall(function() return penModel:GetBoundingBox() end)
        if ok and mSize then
            fullW = math.min(mSize.X, mSize.Z)
            fullL = math.max(mSize.X, mSize.Z)
            fullH = math.clamp(mSize.Y, 4.0, 10.0)
        end
    end

    local width = fullW
    local length = fullL
    local height = fullH

    if State.SizeMode == "Compact18" then
        width = 18.0
        length = 18.0
        height = 3.0
    end

    -- Determine Entrance Direction & Plot Alignment Axis (from SpawnPoint / CenterPoint)
    local spawnPart = (plot and plot:FindFirstChild("SpawnPoint"))
        or (plot and plot:FindFirstChild("CenterPoint"))
        or (plot and plot:FindFirstChild("PlotSign"))

    local isAlongZ = true
    local toSpawn = Vector3.new(0, 0, -1) -- default: entrance at -Z (facing SpawnPoint at Z = -230)
    if spawnPart and center then
        local diff = spawnPart.Position - center
        if math.abs(diff.X) > math.abs(diff.Z) then
            isAlongZ = false
            toSpawn = (diff.X < 0) and Vector3.new(-1, 0, 0) or Vector3.new(1, 0, 0)
        else
            isAlongZ = true
            toSpawn = (diff.Z < 0) and Vector3.new(0, 0, -1) or Vector3.new(0, 0, 1)
        end
    end

    if State.SideOrientation == "Flipped" then
        toSpawn = -toSpawn
    end

    local halfW = width / 2
    local halfL = length / 2
    local h = height

    local sides = {}
    local corners = {}

    if isAlongZ then
        -- Plot runs North-South along Z (width along X, length along Z)
        local frontZ = (toSpawn.Z < 0) and (center.Z - halfL) or (center.Z + halfL)
        local backZ  = (toSpawn.Z < 0) and (center.Z + halfL) or (center.Z - halfL)
        local leftX  = (toSpawn.Z < 0) and (center.X - halfW) or (center.X + halfW)
        local rightX = (toSpawn.Z < 0) and (center.X + halfW) or (center.X - halfW)

        sides.Front = {
            Name = "Front",
            Label = "FRONT / ENTRANCE",
            Color = Color3.fromRGB(0, 225, 255),    -- Cyan
            CF = CFrame.new(center.X, center.Y, frontZ),
            Size = Vector3.new(width, h, 0.5),
            LookDir = Vector3.new(center.X, center.Y, frontZ),
        }
        sides.Back = {
            Name = "Back",
            Label = "BACK / REAR",
            Color = Color3.fromRGB(255, 130, 20),   -- Orange
            CF = CFrame.new(center.X, center.Y, backZ),
            Size = Vector3.new(width, h, 0.5),
            LookDir = Vector3.new(center.X, center.Y, backZ),
        }
        sides.Left = {
            Name = "Left",
            Label = "LEFT SIDE",
            Color = Color3.fromRGB(50, 255, 120),   -- Green
            CF = CFrame.new(leftX, center.Y, center.Z),
            Size = Vector3.new(0.5, h, length),
            LookDir = Vector3.new(leftX, center.Y, center.Z),
        }
        sides.Right = {
            Name = "Right",
            Label = "RIGHT SIDE",
            Color = Color3.fromRGB(255, 230, 40),   -- Yellow
            CF = CFrame.new(rightX, center.Y, center.Z),
            Size = Vector3.new(0.5, h, length),
            LookDir = Vector3.new(rightX, center.Y, center.Z),
        }

        corners.FrontLeft  = Vector3.new(leftX,  center.Y, frontZ)
        corners.FrontRight = Vector3.new(rightX, center.Y, frontZ)
        corners.BackLeft   = Vector3.new(leftX,  center.Y, backZ)
        corners.BackRight  = Vector3.new(rightX, center.Y, backZ)
    else
        -- Plot runs East-West along X (width along Z, length along X)
        local frontX = (toSpawn.X < 0) and (center.X - halfL) or (center.X + halfL)
        local backX  = (toSpawn.X < 0) and (center.X + halfL) or (center.X - halfL)
        local leftZ  = (toSpawn.X < 0) and (center.Z + halfW) or (center.Z - halfW)
        local rightZ = (toSpawn.X < 0) and (center.Z - halfW) or (center.Z + halfW)

        sides.Front = {
            Name = "Front",
            Label = "FRONT / ENTRANCE",
            Color = Color3.fromRGB(0, 225, 255),
            CF = CFrame.new(frontX, center.Y, center.Z),
            Size = Vector3.new(0.5, h, width),
            LookDir = Vector3.new(frontX, center.Y, center.Z),
        }
        sides.Back = {
            Name = "Back",
            Label = "BACK / REAR",
            Color = Color3.fromRGB(255, 130, 20),
            CF = CFrame.new(backX, center.Y, center.Z),
            Size = Vector3.new(0.5, h, width),
            LookDir = Vector3.new(backX, center.Y, center.Z),
        }
        sides.Left = {
            Name = "Left",
            Label = "LEFT SIDE",
            Color = Color3.fromRGB(50, 255, 120),
            CF = CFrame.new(center.X, center.Y, leftZ),
            Size = Vector3.new(length, h, 0.5),
            LookDir = Vector3.new(center.X, center.Y, leftZ),
        }
        sides.Right = {
            Name = "Right",
            Label = "RIGHT SIDE",
            Color = Color3.fromRGB(255, 230, 40),
            CF = CFrame.new(center.X, center.Y, rightZ),
            Size = Vector3.new(length, h, 0.5),
            LookDir = Vector3.new(center.X, center.Y, rightZ),
        }

        corners.FrontLeft  = Vector3.new(frontX, center.Y, leftZ)
        corners.FrontRight = Vector3.new(frontX, center.Y, rightZ)
        corners.BackLeft   = Vector3.new(backX,  center.Y, leftZ)
        corners.BackRight  = Vector3.new(backX,  center.Y, rightZ)
    end

    local cf = CFrame.new(center)
    local size = isAlongZ and Vector3.new(width, height, length) or Vector3.new(length, height, width)

    State.PenCenter = center
    State.PenSize = size
    State.PenCFrame = cf
    State.DetectedSource = source

    return {
        Center = center,
        Size = size,
        CF = cf,
        Source = source,
        Sides = sides,
        Corners = corners,
    }
end

-- ================================================================================
-- 2. ESP RENDERING ENGINE (SEPARATE 4 SIDES + CENTER + CORNERS)
-- ================================================================================
local function clearESP()
    if State.EspContainer then
        pcall(function() State.EspContainer:Destroy() end)
        State.EspContainer = nil
    end
    State.Labels = {}
end

local function renderESP()
    clearESP()
    if not State.EspActive then return end

    local bounds = resolvePenBounds()
    if not bounds then return end

    local container = Instance.new("Folder")
    container.Name = "PenBoundsESP_Container"
    container.Parent = Workspace
    State.EspContainer = container

    -- 1. Floor footprint (translucent area fill)
    local floorPart = Instance.new("Part")
    floorPart.Name = "PenFloorMarker"
    floorPart.Anchored = true
    floorPart.CanCollide = false
    floorPart.CanTouch = false
    floorPart.CanQuery = false
    floorPart.Transparency = 1
    floorPart.CFrame = bounds.CF
    floorPart.Size = bounds.Size
    floorPart.Parent = container

    local floorAdorn = Instance.new("BoxHandleAdornment")
    floorAdorn.Name = "FloorFill"
    floorAdorn.Adornee = floorPart
    floorAdorn.Size = Vector3.new(bounds.Size.X, 0.15, bounds.Size.Z)
    floorAdorn.Color3 = Color3.fromRGB(130, 180, 255)
    floorAdorn.Transparency = 0.75
    floorAdorn.AlwaysOnTop = true
    floorAdorn.ZIndex = 1
    floorAdorn.Parent = floorPart

    -- 2. Center Beacon
    local centerPart = Instance.new("Part")
    centerPart.Name = "PenCenterAnchor"
    centerPart.Anchored = true
    centerPart.CanCollide = false
    centerPart.CanTouch = false
    centerPart.Transparency = 1
    centerPart.CFrame = bounds.CF
    centerPart.Size = Vector3.new(1, 1, 1)
    centerPart.Parent = container

    local centerCyl = Instance.new("CylinderHandleAdornment")
    centerCyl.Name = "CenterBeacon"
    centerCyl.Adornee = centerPart
    centerCyl.Radius = 1.6
    centerCyl.Height = bounds.Size.Y + 1.0
    centerCyl.Color3 = Color3.new(1, 1, 1)
    centerCyl.Transparency = 0.4
    centerCyl.AlwaysOnTop = true
    centerCyl.ZIndex = 3
    centerCyl.CFrame = CFrame.Angles(math.rad(90), 0, 0)
    centerCyl.Parent = centerPart

    -- Center Billboard
    local centerBB = Instance.new("BillboardGui")
    centerBB.Name = "CenterLabel"
    centerBB.Adornee = centerPart
    centerBB.Size = UDim2.new(0, 180, 0, 36)
    centerBB.StudsOffset = Vector3.new(0, bounds.Size.Y + 2.5, 0)
    centerBB.AlwaysOnTop = true
    centerBB.Parent = centerPart

    local centerLbl = Instance.new("TextLabel")
    centerLbl.Size = UDim2.new(1, 0, 1, 0)
    centerLbl.BackgroundColor3 = Color3.fromRGB(15, 20, 35)
    centerLbl.BackgroundTransparency = 0.3
    centerLbl.TextColor3 = Color3.fromRGB(240, 245, 255)
    centerLbl.Font = Enum.Font.GothamBold
    centerLbl.TextSize = 11
    local maxDisplay = State.MaxEggs and tostring(State.MaxEggs) or "?"
    centerLbl.Text = string.format("⭐ PEN CENTER (%.1f x %.1f)\n🥚 Eggs: %d / %s", bounds.Size.X, bounds.Size.Z, #State.PlacedEggs, maxDisplay)
    centerLbl.Parent = centerBB
    Instance.new("UICorner", centerLbl).CornerRadius = UDim.new(0, 6)
    local strokeCenter = Instance.new("UIStroke", centerLbl)
    strokeCenter.Color = Color3.fromRGB(130, 180, 255)
    strokeCenter.Thickness = 1.5

    -- 3. The 4 Distinct Sides (Front, Back, Left, Right)
    for sideKey, sideData in pairs(bounds.Sides) do
        local sidePart = Instance.new("Part")
        sidePart.Name = "PenSideAnchor_" .. sideKey
        sidePart.Anchored = true
        sidePart.CanCollide = false
        sidePart.CanTouch = false
        sidePart.Transparency = 1
        sidePart.CFrame = sideData.CF
        sidePart.Size = sideData.Size
        sidePart.Parent = container

        -- 3D Wall Beam
        local wallAdorn = Instance.new("BoxHandleAdornment")
        wallAdorn.Name = "WallBox_" .. sideKey
        wallAdorn.Adornee = sidePart
        wallAdorn.Size = sideData.Size
        wallAdorn.Color3 = sideData.Color
        wallAdorn.Transparency = 0.35
        wallAdorn.AlwaysOnTop = true
        wallAdorn.ZIndex = 4
        wallAdorn.Parent = sidePart

        -- Billboard Label for this side
        local sideBB = Instance.new("BillboardGui")
        sideBB.Name = "BB_" .. sideKey
        sideBB.Adornee = sidePart
        sideBB.Size = UDim2.new(0, 140, 0, 30)
        sideBB.StudsOffset = Vector3.new(0, sideData.Size.Y / 2 + 1.8, 0)
        sideBB.AlwaysOnTop = true
        sideBB.Parent = sidePart

        local sideLbl = Instance.new("TextLabel")
        sideLbl.Size = UDim2.new(1, 0, 1, 0)
        sideLbl.BackgroundColor3 = Color3.fromRGB(12, 16, 24)
        sideLbl.BackgroundTransparency = 0.25
        sideLbl.TextColor3 = sideData.Color
        sideLbl.Font = Enum.Font.GothamBold
        sideLbl.TextSize = 10
        sideLbl.Text = string.format("[%s]\nDist: ...", sideData.Label or string.upper(sideKey))
        sideLbl.Parent = sideBB
        Instance.new("UICorner", sideLbl).CornerRadius = UDim.new(0, 5)
        local stroke = Instance.new("UIStroke", sideLbl)
        stroke.Color = sideData.Color
        stroke.Thickness = 1.5

        State.Labels[sideKey] = {
            Label = sideLbl,
            Pos = sideData.CF.Position,
            Name = sideData.Label or string.upper(sideKey),
        }
    end

    -- 4. Four Corner Pillars (Purple)
    for cornerKey, cornerPos in pairs(bounds.Corners) do
        local cPart = Instance.new("Part")
        cPart.Name = "Corner_" .. cornerKey
        cPart.Anchored = true
        cPart.CanCollide = false
        cPart.Transparency = 1
        cPart.CFrame = CFrame.new(cornerPos)
        cPart.Size = Vector3.new(0.6, bounds.Size.Y + 2.0, 0.6)
        cPart.Parent = container

        local cAdorn = Instance.new("CylinderHandleAdornment")
        cAdorn.Name = "CornerPillar"
        cAdorn.Adornee = cPart
        cAdorn.Radius = 0.45
        cAdorn.Height = bounds.Size.Y + 2.0
        cAdorn.Color3 = Color3.fromRGB(200, 90, 255)
        cAdorn.Transparency = 0.25
        cAdorn.AlwaysOnTop = true
        cAdorn.ZIndex = 5
        cAdorn.CFrame = CFrame.Angles(math.rad(90), 0, 0)
        cAdorn.Parent = cPart
    end

    -- 5. Individual Egg Slot Markers (Visual Ghost Rings on Floor)
    if State.ShowSlotGrid then
        local sCap, sCols, sRows = getSpatialCapacity(bounds.Size)
        local totalSlots = State.MaxEggs or sCap
        local cols = sCols
        local rows = sRows
        if totalSlots ~= sCap and totalSlots > 0 then
            local aspect = bounds.Size.X / bounds.Size.Z
            cols = math.max(1, math.ceil(math.sqrt(totalSlots * aspect)))
            rows = math.max(1, math.ceil(totalSlots / cols))
        end

        local halfW = bounds.Size.X / 2
        local halfD = bounds.Size.Z / 2
        local cellW = bounds.Size.X / cols
        local cellD = bounds.Size.Z / rows

        local slotNum = 0
        for r = 1, rows do
            for c = 1, cols do
                slotNum = slotNum + 1
                if slotNum <= totalSlots then
                    local relX = -halfW + (c - 0.5) * cellW
                    local relZ = -halfD + (r - 0.5) * cellD
                    local slotPos = (bounds.CF * CFrame.new(relX, -bounds.Size.Y / 2 + 0.05, relZ)).Position

                    -- Check if any placed egg is close to this slot
                    local isOccupied = false
                    for _, pe in ipairs(State.PlacedEggs) do
                        local dx = pe.Pos.X - slotPos.X
                        local dz = pe.Pos.Z - slotPos.Z
                        if math.sqrt(dx * dx + dz * dz) <= 2.2 then
                            isOccupied = true
                            break
                        end
                    end

                    local slotPart = Instance.new("Part")
                    slotPart.Name = string.format("PenSlotMarker_%d", slotNum)
                    slotPart.Anchored = true
                    slotPart.CanCollide = false
                    slotPart.CanTouch = false
                    slotPart.Transparency = 1
                    slotPart.CFrame = CFrame.new(slotPos)
                    slotPart.Size = Vector3.new(2, 0.2, 2)
                    slotPart.Parent = container

                    local slotRing = Instance.new("CylinderHandleAdornment")
                    slotRing.Name = "SlotRing"
                    slotRing.Adornee = slotPart
                    slotRing.Radius = 1.15
                    slotRing.Height = 0.12
                    slotRing.Color3 = isOccupied and Color3.fromRGB(0, 225, 255) or Color3.fromRGB(60, 230, 110)
                    slotRing.Transparency = isOccupied and 0.35 or 0.70
                    slotRing.AlwaysOnTop = true
                    slotRing.ZIndex = 2
                    slotRing.CFrame = CFrame.Angles(math.rad(90), 0, 0)
                    slotRing.Parent = slotPart

                    local slotBB = Instance.new("BillboardGui")
                    slotBB.Name = "SlotBB"
                    slotBB.Adornee = slotPart
                    slotBB.Size = UDim2.new(0, 60, 0, 18)
                    slotBB.StudsOffset = Vector3.new(0, 0.8, 0)
                    slotBB.AlwaysOnTop = true
                    slotBB.Parent = slotPart

                    local slotLbl = Instance.new("TextLabel")
                    slotLbl.Size = UDim2.new(1, 0, 1, 0)
                    slotLbl.BackgroundColor3 = Color3.fromRGB(15, 20, 30)
                    slotLbl.BackgroundTransparency = 0.4
                    slotLbl.TextColor3 = isOccupied and Color3.fromRGB(0, 225, 255) or Color3.fromRGB(180, 255, 190)
                    slotLbl.Font = Enum.Font.GothamBold
                    slotLbl.TextSize = 9
                    slotLbl.Text = isOccupied and string.format("#%d [OCC]", slotNum) or string.format("#%d [FREE]", slotNum)
                    slotLbl.Parent = slotBB
                    Instance.new("UICorner", slotLbl).CornerRadius = UDim.new(0, 4)
                end
            end
        end
    end

    logMsg("✓ Rendered 4 sides ESP for Pen: %s at (%.1f, %.1f, %.1f) | Size: (%.1f x %.1f)",
        bounds.Source, bounds.Center.X, bounds.Center.Y, bounds.Center.Z, bounds.Size.X, bounds.Size.Z)
end

-- ================================================================================
-- 3. WALKING / NAVIGATION TEST
-- ================================================================================
local function walkTo(dest, arriveDist)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum then return false end

    arriveDist = arriveDist or 2.5
    local t0 = os.clock()

    while char.Parent and hum.Health > 0 and (os.clock() - t0 < 15) do
        local d = (root.Position - dest).Magnitude
        if d <= arriveDist then
            pcall(function() hum:Move(Vector3.zero) end)
            return true
        end
        hum:MoveTo(dest)
        task.wait(0.08)
    end
    pcall(function() hum:Move(Vector3.zero) end)
    return false
end

-- ================================================================================
-- 4. INTERACTIVE DIAGNOSTIC HUD
-- ================================================================================
local function buildUI()
    local getHui = gethui or function() return CoreGui end
    local uiParent = nil
    pcall(function() uiParent = getHui() end)
    if not uiParent then uiParent = LocalPlayer:FindFirstChild("PlayerGui") or CoreGui end

    local old = uiParent:FindFirstChild("PenBoundsESP_HUD")
    if old then pcall(function() old:Destroy() end) end

    local gui = Instance.new("ScreenGui")
    gui.Name = "PenBoundsESP_HUD"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 99999
    pcall(function() gui.Parent = uiParent end)
    if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    local main = Instance.new("Frame")
    main.Size = UDim2.new(0, 420, 0, 560)
    main.Position = UDim2.new(0, 30, 0.5, -280)
    main.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
    main.BorderSizePixel = 0
    main.Active = true
    main.Parent = gui
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new("UIStroke", main)
    stroke.Color = Color3.fromRGB(50, 140, 240)
    stroke.Thickness = 1.5

    -- Title Bar (Draggable)
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 38)
    titleBar.BackgroundColor3 = Color3.fromRGB(24, 30, 46)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = main
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -45, 1, 0)
    titleLbl.Position = UDim2.new(0, 12, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "📐 PEN BOUNDS & 4-SIDE ESP 🥚"
    titleLbl.TextColor3 = Color3.fromRGB(230, 240, 255)
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 13
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = titleBar

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 26, 0, 26)
    closeBtn.Position = UDim2.new(1, -32, 0, 6)
    closeBtn.BackgroundColor3 = Color3.fromRGB(190, 50, 50)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 12
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)
    closeBtn.MouseButton1Click:Connect(function()
        clearESP()
        if State.UpdateConnection then State.UpdateConnection:Disconnect() end
        gui:Destroy()
    end)

    -- Draggable
    local dragging, dragStart, startPos = false, nil, nil
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; startPos = main.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    -- Content Scroll
    local content = Instance.new("ScrollingFrame")
    content.Size = UDim2.new(1, -20, 1, -50)
    content.Position = UDim2.new(0, 10, 0, 44)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ScrollBarThickness = 4
    content.CanvasSize = UDim2.new(0, 0, 0, 990)
    content.Parent = main

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 8)
    layout.Parent = content

    -- 1. Detection Info Card
    local infoCard = Instance.new("Frame")
    infoCard.Size = UDim2.new(1, 0, 0, 105)
    infoCard.BackgroundColor3 = Color3.fromRGB(22, 28, 42)
    infoCard.Parent = content
    Instance.new("UICorner", infoCard).CornerRadius = UDim.new(0, 6)

    local infoLbl = Instance.new("TextLabel")
    infoLbl.Size = UDim2.new(1, -16, 1, -10)
    infoLbl.Position = UDim2.new(0, 8, 0, 5)
    infoLbl.BackgroundTransparency = 1
    infoLbl.TextColor3 = Color3.fromRGB(200, 220, 255)
    infoLbl.Font = Enum.Font.Code
    infoLbl.TextSize = 11
    infoLbl.TextXAlignment = Enum.TextXAlignment.Left
    infoLbl.TextYAlignment = Enum.TextYAlignment.Top
    infoLbl.Text = "Detecting pen location & capacity..."
    infoLbl.Parent = infoCard

    local function updateInfoText()
        local c = State.PenCenter or Vector3.zero
        local s = State.PenSize or Vector3.zero
        local plotName = State.MyPlot and State.MyPlot.Name or "None"
        local maxStr = State.MaxEggs and tostring(State.MaxEggs) or "?"
        local maxSrc = State.MaxEggsSource or "Probing..."
        infoLbl.Text = string.format(
            "Source:  %s\nPlot:    #%s (Model: %s)\nCenter:  (%.1f, %.1f, %.1f)\nSize:    %.1fW x %.1fD studs\nEggs:    %d / %s in Pen\nLimit:   %s",
            State.DetectedSource or "Scanning...",
            tostring(State.MyPlotIndex or "?"),
            plotName,
            c.X, c.Y, c.Z,
            s.X, s.Z,
            #State.PlacedEggs,
            maxStr,
            maxSrc
        )
    end

    -- 2. Toggle ESP Button
    local espBtn = Instance.new("TextButton")
    espBtn.Size = UDim2.new(1, 0, 0, 30)
    espBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
    espBtn.Text = "4-SIDE WALL ESP: ACTIVE [ON]"
    espBtn.TextColor3 = Color3.new(1, 1, 1)
    espBtn.Font = Enum.Font.GothamBold
    espBtn.TextSize = 11
    espBtn.Parent = content
    Instance.new("UICorner", espBtn).CornerRadius = UDim.new(0, 6)

    espBtn.MouseButton1Click:Connect(function()
        State.EspActive = not State.EspActive
        if State.EspActive then
            espBtn.Text = "4-SIDE WALL ESP: ACTIVE [ON]"
            espBtn.BackgroundColor3 = Color3.fromRGB(35, 135, 75)
            renderESP()
        else
            espBtn.Text = "4-SIDE WALL ESP: DISABLED [OFF]"
            espBtn.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
            clearESP()
        end
    end)

    -- 3. Toggle Slot Grid ESP Button
    local gridBtn = Instance.new("TextButton")
    gridBtn.Size = UDim2.new(1, 0, 0, 30)
    gridBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 180)
    gridBtn.Text = "SLOT GRID ESP: ACTIVE [ON]"
    gridBtn.TextColor3 = Color3.new(1, 1, 1)
    gridBtn.Font = Enum.Font.GothamBold
    gridBtn.TextSize = 11
    gridBtn.Parent = content
    Instance.new("UICorner", gridBtn).CornerRadius = UDim.new(0, 6)

    gridBtn.MouseButton1Click:Connect(function()
        State.ShowSlotGrid = not State.ShowSlotGrid
        if State.ShowSlotGrid then
            gridBtn.Text = "SLOT GRID ESP: ACTIVE [ON]"
            gridBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 180)
        else
            gridBtn.Text = "SLOT GRID ESP: DISABLED [OFF]"
            gridBtn.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
        end
        renderESP()
    end)

    -- 4. Capacity Discovery & Probe Card
    local capCard = Instance.new("Frame")
    capCard.Size = UDim2.new(1, 0, 0, 68)
    capCard.BackgroundColor3 = Color3.fromRGB(25, 32, 48)
    capCard.Parent = content
    Instance.new("UICorner", capCard).CornerRadius = UDim.new(0, 6)

    local probeBtn = Instance.new("TextButton")
    probeBtn.Size = UDim2.new(1, -16, 0, 28)
    probeBtn.Position = UDim2.new(0, 8, 0, 6)
    probeBtn.BackgroundColor3 = Color3.fromRGB(150, 70, 200)
    probeBtn.Text = "🔍 PROBE PEN CAPACITY (HOMESTEAD/PROFILE/UI)"
    probeBtn.TextColor3 = Color3.new(1, 1, 1)
    probeBtn.Font = Enum.Font.GothamBold
    probeBtn.TextSize = 10
    probeBtn.Parent = capCard
    Instance.new("UICorner", probeBtn).CornerRadius = UDim.new(0, 5)

    -- Row for Manual Max Override: [-] [Val] [+] [AUTO]
    local adjRow = Instance.new("Frame")
    adjRow.Size = UDim2.new(1, -16, 0, 24)
    adjRow.Position = UDim2.new(0, 8, 0, 38)
    adjRow.BackgroundTransparency = 1
    adjRow.Parent = capCard

    local adjTitle = Instance.new("TextLabel")
    adjTitle.Size = UDim2.new(0, 120, 1, 0)
    adjTitle.BackgroundTransparency = 1
    adjTitle.TextColor3 = Color3.fromRGB(210, 220, 240)
    adjTitle.Font = Enum.Font.Gotham
    adjTitle.TextSize = 11
    adjTitle.TextXAlignment = Enum.TextXAlignment.Left
    adjTitle.Text = "Manual Max Eggs:"
    adjTitle.Parent = adjRow

    local minusBtn = Instance.new("TextButton")
    minusBtn.Size = UDim2.new(0, 26, 1, 0)
    minusBtn.Position = UDim2.new(0, 125, 0, 0)
    minusBtn.BackgroundColor3 = Color3.fromRGB(45, 55, 75)
    minusBtn.Text = "−"
    minusBtn.TextColor3 = Color3.new(1, 1, 1)
    minusBtn.Font = Enum.Font.GothamBold
    minusBtn.TextSize = 14
    minusBtn.Parent = adjRow
    Instance.new("UICorner", minusBtn).CornerRadius = UDim.new(0, 4)

    local capValLbl = Instance.new("TextLabel")
    capValLbl.Size = UDim2.new(0, 40, 1, 0)
    capValLbl.Position = UDim2.new(0, 155, 0, 0)
    capValLbl.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
    capValLbl.TextColor3 = Color3.fromRGB(255, 230, 80)
    capValLbl.Font = Enum.Font.GothamBold
    capValLbl.TextSize = 11
    capValLbl.Text = tostring(State.MaxEggs or "?")
    capValLbl.Parent = adjRow
    Instance.new("UICorner", capValLbl).CornerRadius = UDim.new(0, 4)

    local plusBtn = Instance.new("TextButton")
    plusBtn.Size = UDim2.new(0, 26, 1, 0)
    plusBtn.Position = UDim2.new(0, 199, 0, 0)
    plusBtn.BackgroundColor3 = Color3.fromRGB(45, 55, 75)
    plusBtn.Text = "+"
    plusBtn.TextColor3 = Color3.new(1, 1, 1)
    plusBtn.Font = Enum.Font.GothamBold
    plusBtn.TextSize = 14
    plusBtn.Parent = adjRow
    Instance.new("UICorner", plusBtn).CornerRadius = UDim.new(0, 4)

    local autoBtn = Instance.new("TextButton")
    autoBtn.Size = UDim2.new(0, 55, 1, 0)
    autoBtn.Position = UDim2.new(1, -55, 0, 0)
    autoBtn.BackgroundColor3 = Color3.fromRGB(30, 80, 140)
    autoBtn.Text = "AUTO"
    autoBtn.TextColor3 = Color3.new(1, 1, 1)
    autoBtn.Font = Enum.Font.GothamBold
    autoBtn.TextSize = 10
    autoBtn.Parent = adjRow
    Instance.new("UICorner", autoBtn).CornerRadius = UDim.new(0, 4)

    minusBtn.MouseButton1Click:Connect(function()
        local cur = State.MaxEggs or 5
        if cur > 1 then
            State.MaxEggs = cur - 1
            State.MaxEggsSource = "Manual Override"
            capValLbl.Text = tostring(State.MaxEggs)
            updateInfoText()
            renderESP()
        end
    end)

    plusBtn.MouseButton1Click:Connect(function()
        local cur = State.MaxEggs or 5
        State.MaxEggs = cur + 1
        State.MaxEggsSource = "Manual Override"
        capValLbl.Text = tostring(State.MaxEggs)
        updateInfoText()
        renderESP()
    end)

    autoBtn.MouseButton1Click:Connect(function()
        probePenCapacity()
        capValLbl.Text = tostring(State.MaxEggs or "?")
        updateInfoText()
        renderESP()
    end)

    probeBtn.MouseButton1Click:Connect(function()
        probeBtn.Text = "PROBING ALL REMOTES & UI..."
        task.spawn(function()
            probePenCapacity()
            capValLbl.Text = tostring(State.MaxEggs or "?")
            updateInfoText()
            renderESP()
            task.wait(0.5)
            probeBtn.Text = "🔍 PROBE PEN CAPACITY (HOMESTEAD/PROFILE/UI)"
        end)
    end)

    -- 3. Sides Legend & Distances
    local legendCard = Instance.new("Frame")
    legendCard.Size = UDim2.new(1, 0, 0, 85)
    legendCard.BackgroundColor3 = Color3.fromRGB(22, 28, 42)
    legendCard.Parent = content
    Instance.new("UICorner", legendCard).CornerRadius = UDim.new(0, 6)

    local legendLbl = Instance.new("TextLabel")
    legendLbl.Size = UDim2.new(1, -16, 1, -10)
    legendLbl.Position = UDim2.new(0, 8, 0, 5)
    legendLbl.BackgroundTransparency = 1
    legendLbl.TextColor3 = Color3.fromRGB(240, 240, 255)
    legendLbl.Font = Enum.Font.Gotham
    legendLbl.TextSize = 11
    legendLbl.TextXAlignment = Enum.TextXAlignment.Left
    legendLbl.RichText = true
    legendLbl.Text = "<b>Pen Sides Legend:</b>\n" ..
        '<font color="#00e1ff">■ FRONT (+Z): Cyan</font>    ' ..
        '<font color="#ff8214">■ BACK (-Z): Orange</font>\n' ..
        '<font color="#32ff78">■ LEFT (-X): Green</font>    ' ..
        '<font color="#ffe628">■ RIGHT (+X): Yellow</font>\n' ..
        '<font color="#c85aff">■ 4 Corners: Purple Pillars</font>'
    legendLbl.Parent = legendCard

    -- 4. Interactive Walk Test Header
    local testHeader = Instance.new("TextLabel")
    testHeader.Size = UDim2.new(1, 0, 0, 20)
    testHeader.BackgroundTransparency = 1
    testHeader.Text = "INTERACTIVE WALK TESTS (VERIFY SIDES):"
    testHeader.TextColor3 = Color3.fromRGB(130, 180, 255)
    testHeader.Font = Enum.Font.GothamBold
    testHeader.TextSize = 11
    testHeader.TextXAlignment = Enum.TextXAlignment.Left
    testHeader.Parent = content

    local function makeWalkBtn(txt, color, targetFunc)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 28)
        btn.BackgroundColor3 = color
        btn.Text = txt
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.Parent = content
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
        btn.MouseButton1Click:Connect(function()
            if State.NavThread then
                task.cancel(State.NavThread)
                State.NavThread = nil
            end
            btn.Text = "WALKING..."
            State.NavThread = task.spawn(function()
                local dest = targetFunc()
                if dest then
                    walkTo(dest, 2.5)
                end
                btn.Text = txt
                State.NavThread = nil
            end)
        end)
    end

    makeWalkBtn("🚶 Walk to Pen CENTER", Color3.fromRGB(45, 90, 160), function()
        return State.PenCenter
    end)

    makeWalkBtn("🚶 Walk to FRONT Side (Cyan / Entrance)", Color3.fromRGB(0, 140, 170), function()
        local bounds = resolvePenBounds()
        return bounds and bounds.Sides.Front.CF.Position
    end)

    makeWalkBtn("🚶 Walk to BACK Side (Orange / Rear)", Color3.fromRGB(180, 85, 20), function()
        local bounds = resolvePenBounds()
        return bounds and bounds.Sides.Back.CF.Position
    end)

    makeWalkBtn("🚶 Walk to LEFT Side (Green / EventBoard)", Color3.fromRGB(35, 140, 75), function()
        local bounds = resolvePenBounds()
        return bounds and bounds.Sides.Left.CF.Position
    end)

    makeWalkBtn("🚶 Walk to RIGHT Side (Yellow / Treadmill)", Color3.fromRGB(170, 150, 25), function()
        local bounds = resolvePenBounds()
        return bounds and bounds.Sides.Right.CF.Position
    end)

    -- Center Mode Selector Button
    local modeBtn = Instance.new("TextButton")
    modeBtn.Size = UDim2.new(1, 0, 0, 28)
    modeBtn.BackgroundColor3 = Color3.fromRGB(30, 80, 130)
    modeBtn.Text = string.format("🎯 Center Mode: %s (Click to Switch)", State.CenterMode)
    modeBtn.TextColor3 = Color3.new(1, 1, 1)
    modeBtn.Font = Enum.Font.GothamBold
    modeBtn.TextSize = 11
    modeBtn.Parent = content
    Instance.new("UICorner", modeBtn).CornerRadius = UDim.new(0, 5)
    modeBtn.MouseButton1Click:Connect(function()
        if State.CenterMode == "Auto" then
            State.CenterMode = "PenModel"
        elseif State.CenterMode == "PenModel" then
            State.CenterMode = "PlotPivot"
        elseif State.CenterMode == "PlotPivot" then
            State.CenterMode = "CenterPoint"
        else
            State.CenterMode = "Auto"
        end
        modeBtn.Text = string.format("🎯 Center Mode: %s (Click to Switch)", State.CenterMode)
        logMsg("Switched Center Mode to: %s", State.CenterMode)
        renderESP()
    end)

    -- Size Mode Selector Button
    local sizeBtn = Instance.new("TextButton")
    sizeBtn.Size = UDim2.new(1, 0, 0, 28)
    sizeBtn.BackgroundColor3 = Color3.fromRGB(25, 95, 90)
    sizeBtn.Text = string.format("📐 Size Mode: %s (Click to Switch)", State.SizeMode == "FullPen" and "Full Pen (50x113)" or "Compact (18x18)")
    sizeBtn.TextColor3 = Color3.new(1, 1, 1)
    sizeBtn.Font = Enum.Font.GothamBold
    sizeBtn.TextSize = 11
    sizeBtn.Parent = content
    Instance.new("UICorner", sizeBtn).CornerRadius = UDim.new(0, 5)
    sizeBtn.MouseButton1Click:Connect(function()
        if State.SizeMode == "FullPen" then
            State.SizeMode = "Compact18"
        else
            State.SizeMode = "FullPen"
        end
        sizeBtn.Text = string.format("📐 Size Mode: %s (Click to Switch)", State.SizeMode == "FullPen" and "Full Pen (50x113)" or "Compact (18x18)")
        logMsg("Switched Pen Size Mode to: %s", State.SizeMode)
        renderESP()
    end)

    -- Side Orientation Flip Button
    local flipBtn = Instance.new("TextButton")
    flipBtn.Size = UDim2.new(1, 0, 0, 28)
    flipBtn.BackgroundColor3 = Color3.fromRGB(90, 60, 30)
    flipBtn.Text = string.format("🔄 Front/Back: %s (Click to Flip)", State.SideOrientation)
    flipBtn.TextColor3 = Color3.new(1, 1, 1)
    flipBtn.Font = Enum.Font.GothamBold
    flipBtn.TextSize = 11
    flipBtn.Parent = content
    Instance.new("UICorner", flipBtn).CornerRadius = UDim.new(0, 5)
    flipBtn.MouseButton1Click:Connect(function()
        if State.SideOrientation == "Auto" then
            State.SideOrientation = "Flipped"
        else
            State.SideOrientation = "Auto"
        end
        flipBtn.Text = string.format("🔄 Front/Back: %s (Click to Flip)", State.SideOrientation)
        logMsg("Switched Side Orientation to: %s", State.SideOrientation)
        renderESP()
    end)

    -- 5. Diagnostic Dump Button
    local dumpBtn = Instance.new("TextButton")
    dumpBtn.Size = UDim2.new(1, 0, 0, 28)
    dumpBtn.BackgroundColor3 = Color3.fromRGB(80, 45, 120)
    dumpBtn.Text = "📁 Dump Plot & Pen Hierarchy to Log"
    dumpBtn.TextColor3 = Color3.new(1, 1, 1)
    dumpBtn.Font = Enum.Font.GothamBold
    dumpBtn.TextSize = 11
    dumpBtn.Parent = content
    Instance.new("UICorner", dumpBtn).CornerRadius = UDim.new(0, 5)
    dumpBtn.MouseButton1Click:Connect(function()
        logMsg("================ PLOT HIERARCHY DUMP ================")
        if State.MyPlot then
            logMsg("Plot Instance: %s (Class: %s)", State.MyPlot:GetFullName(), State.MyPlot.ClassName)
            for _, d in ipairs(State.MyPlot:GetDescendants()) do
                if d:IsA("BasePart") or d:IsA("Model") or d:IsA("TextLabel") then
                    local pStr = ""
                    if d:IsA("BasePart") then
                        pStr = string.format("Pos:(%.1f, %.1f, %.1f) Sz:(%.1f, %.1f, %.1f)", d.Position.X, d.Position.Y, d.Position.Z, d.Size.X, d.Size.Y, d.Size.Z)
                    elseif d:IsA("Model") then
                        local ok, cfM, s = pcall(function() return d:GetBoundingBox() end)
                        if ok and cfM and s then
                            pStr = string.format("Pos:(%.1f, %.1f, %.1f) BBox:(%.1f, %.1f, %.1f)", cfM.Position.X, cfM.Position.Y, cfM.Position.Z, s.X, s.Y, s.Z)
                        end
                    end
                    logMsg("  - [%s] %s %s", d.ClassName, d.Name, pStr)
                end
            end
        else
            logMsg("No plot detected. Placed eggs count: %d", #State.PlacedEggs)
        end
        logMsg("=====================================================")
    end)

    -- 5b. Group Bag Eggs Button
    local bagBtn = Instance.new("TextButton")
    bagBtn.Size = UDim2.new(1, 0, 0, 28)
    bagBtn.BackgroundColor3 = Color3.fromRGB(35, 120, 85)
    bagBtn.Text = "🎒 Group Current Bag Eggs (Inspect & Log)"
    bagBtn.TextColor3 = Color3.new(1, 1, 1)
    bagBtn.Font = Enum.Font.GothamBold
    bagBtn.TextSize = 11
    bagBtn.Parent = content
    Instance.new("UICorner", bagBtn).CornerRadius = UDim.new(0, 5)
    bagBtn.MouseButton1Click:Connect(function()
        bagBtn.Text = "SCANNING BAG..."
        task.spawn(function()
            dumpBagGrouping()
            bagBtn.Text = "🎒 Group Current Bag Eggs (Inspect & Log)"
        end)
    end)

    -- 6. Live Log Terminal & Copy Toolbar
    local logCard = Instance.new("Frame")
    logCard.Size = UDim2.new(1, 0, 0, 240)
    logCard.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
    logCard.Parent = content
    Instance.new("UICorner", logCard).CornerRadius = UDim.new(0, 8)
    local logCardStroke = Instance.new("UIStroke", logCard)
    logCardStroke.Color = Color3.fromRGB(45, 60, 90)

    -- Log Header Bar with Copy & Clear buttons
    local logHeader = Instance.new("Frame")
    logHeader.Size = UDim2.new(1, 0, 0, 32)
    logHeader.BackgroundColor3 = Color3.fromRGB(20, 26, 40)
    logHeader.Parent = logCard
    Instance.new("UICorner", logHeader).CornerRadius = UDim.new(0, 8)

    local logTitle = Instance.new("TextLabel")
    logTitle.Size = UDim2.new(0, 170, 1, 0)
    logTitle.Position = UDim2.new(0, 8, 0, 0)
    logTitle.BackgroundTransparency = 1
    logTitle.Text = "📜 LIVE LOG & PROBE REPORT"
    logTitle.TextColor3 = Color3.fromRGB(220, 235, 255)
    logTitle.Font = Enum.Font.GothamBold
    logTitle.TextSize = 10
    logTitle.TextXAlignment = Enum.TextXAlignment.Left
    logTitle.Parent = logHeader

    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(0, 105, 0, 22)
    copyBtn.Position = UDim2.new(1, -170, 0, 5)
    copyBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 210)
    copyBtn.Text = "📋 COPY LOG"
    copyBtn.TextColor3 = Color3.new(1, 1, 1)
    copyBtn.Font = Enum.Font.GothamBold
    copyBtn.TextSize = 10
    copyBtn.Parent = logHeader
    Instance.new("UICorner", copyBtn).CornerRadius = UDim.new(0, 4)

    local clearBtn = Instance.new("TextButton")
    clearBtn.Size = UDim2.new(0, 55, 0, 22)
    clearBtn.Position = UDim2.new(1, -60, 0, 5)
    clearBtn.BackgroundColor3 = Color3.fromRGB(50, 55, 70)
    clearBtn.Text = "🗑️ CLEAR"
    clearBtn.TextColor3 = Color3.fromRGB(220, 220, 230)
    clearBtn.Font = Enum.Font.GothamBold
    clearBtn.TextSize = 10
    clearBtn.Parent = logHeader
    Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0, 4)

    -- Scrollable Log Container
    local logScroll = Instance.new("ScrollingFrame")
    logScroll.Size = UDim2.new(1, -12, 1, -40)
    logScroll.Position = UDim2.new(0, 6, 0, 36)
    logScroll.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
    logScroll.BorderSizePixel = 0
    logScroll.ScrollBarThickness = 5
    logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    logScroll.Parent = logCard
    Instance.new("UICorner", logScroll).CornerRadius = UDim.new(0, 6)

    -- Selectable TextBox so mobile or any executor can copy text natively
    local logTxt = Instance.new("TextBox")
    logTxt.Size = UDim2.new(1, -8, 0, 20)
    logTxt.Position = UDim2.new(0, 4, 0, 4)
    logTxt.BackgroundTransparency = 1
    logTxt.TextColor3 = Color3.fromRGB(200, 220, 245)
    logTxt.Font = Enum.Font.Code
    logTxt.TextSize = 10
    logTxt.TextXAlignment = Enum.TextXAlignment.Left
    logTxt.TextYAlignment = Enum.TextYAlignment.Top
    logTxt.TextWrapped = true
    logTxt.ClearTextOnFocus = false
    logTxt.TextEditable = false
    logTxt.MultiLine = true
    logTxt.Text = "Logs will appear here... Click [📋 COPY LOG] to copy anytime."
    logTxt.Parent = logScroll

    local function refreshLogView()
        local fullText = #logEntries > 0 and table.concat(logEntries, "\n") or "No logs recorded yet."
        logTxt.Text = fullText
        local tb = logTxt.TextBounds
        logTxt.Size = UDim2.new(1, -8, 0, math.max(tb.Y + 20, 180))
        logScroll.CanvasSize = UDim2.new(0, 0, 0, tb.Y + 30)
        logScroll.CanvasPosition = Vector2.new(0, math.max(0, tb.Y - logScroll.AbsoluteSize.Y + 30))
    end

    logCallback = function()
        refreshLogView()
    end

    copyBtn.MouseButton1Click:Connect(function()
        local fullText = table.concat(logEntries, "\n")
        local copied = false
        if setclipboard then
            local s, _ = pcall(setclipboard, fullText)
            copied = s
        elseif toclipboard then
            local s, _ = pcall(toclipboard, fullText)
            copied = s
        elseif typeof(syn) == "table" and syn.write_clipboard then
            local s, _ = pcall(syn.write_clipboard, fullText)
            copied = s
        end

        if copied then
            copyBtn.Text = "✓ COPIED!"
            copyBtn.BackgroundColor3 = Color3.fromRGB(35, 140, 75)
        else
            -- Clipboard API not directly exposed; select all text for manual copy
            pcall(function() logTxt:CaptureFocus() end)
            copyBtn.Text = "✓ SELECTED (Ctrl+C)"
            copyBtn.BackgroundColor3 = Color3.fromRGB(180, 120, 30)
        end
        task.delay(1.8, function()
            if copyBtn and copyBtn.Parent then
                copyBtn.Text = "📋 COPY LOG"
                copyBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 210)
            end
        end)
    end)

    clearBtn.MouseButton1Click:Connect(function()
        table.clear(logEntries)
        refreshLogView()
    end)

    refreshLogView()

    -- Initial ESP Render
    renderESP()
    updateInfoText()

    -- Live distance updater on Heartbeat
    State.UpdateConnection = RunService.Heartbeat:Connect(function()
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then return end

        for sideKey, data in pairs(State.Labels) do
            local d = (root.Position - data.Pos).Magnitude
            if data.Label and data.Label.Parent then
                local lblName = data.Name or string.upper(sideKey)
                data.Label.Text = string.format("[%s]\n%.1f studs", lblName, d)
            end
        end
    end)
end

-- Launch
probePenCapacity()
buildUI()
logMsg("Pen Bounds, Capacity Probe & 4-Side ESP Inspector initialized.")
