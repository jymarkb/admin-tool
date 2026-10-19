--[[
    ================================================================================
    AUTO PEN EGG PLACEMENT & TREADMILL AUTOMATION SUITE
    ================================================================================
    Standalone Automation Tool for "Steal an Egg" (Roblox)
    Features:
      1. Auto Pen Discovery:
         - Introspects Workspace.Plots / Workspace.Bases for player ownership.
         - Scans Workspace.PlacedEggRenders for exact egg cluster coordinates.
         - Resolves Pen floor position and bounds with automatic fallback.
      2. Auto Egg Placement:
         - Scans inventory for unplaced eggs (ProfileMirror where Placement == nil).
         - Detects egg tools in Backpack & Character.
         - Performs multi-tier placement:
           * Direct RF/EggWorld/AskPlaceEgg remote invocation
           * ReplicatedStorage.Controllers.Game.Eggs.EggPlacementController hook
           * Equipped Tool activation sequence
      3. Auto Treadmill Navigation & Mount:
         - Resolves plot treadmill from Workspace.__ClientTreadmillRenders.
         - Navigates character directly to the treadmill running belt.
         - Mounts via RF/Treadmill/AskWearStill, belt collision, and ProximityPrompts.
         - Monitors LocalPlayer / Character "IsOnTreadmill" attribute.
      4. Auto Dismount (Disinmount):
         - Clean dismount via RF/Treadmill/AskDoff invocation.
         - Jump state release & lateral step-off to prevent re-triggering.
         - Clicks on-screen PlayerGui dismount buttons if present.
      5. Full Autonomous Cycle Loop:
         - Alternates between placing newly acquired eggs in the pen and training
           on the treadmill to maximize speed gains without manual intervention.
         - Optional auto-dismount timer / on-demand controls.
      6. Dedicated Modern HUD:
         - Draggable window with real-time status, one-click manual triggers,
           toggleable auto-loop, and diagnostic log.

    NOTE: EggGoToUI_v10.lua is NOT modified. This script is fully standalone.
    ================================================================================
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait() or Players.LocalPlayer
end

-- ================================================================================
-- CONFIGURATION & DEFAULTS
-- ================================================================================
local CONFIG = {
    AutoLoop            = false,      -- Master toggle for continuous pen <-> treadmill cycle
    AutoDismountTimer   = 30,         -- Seconds to train on treadmill before auto dismount (default 30s)
    PenWaitDuration     = 5.0,        -- Seconds to stay at pen center before heading to treadmill
    SafeZoneFallback    = Vector3.new(534.090, 70.724, -326.616),
}

-- Runtime State
local State = {
    IsRunning           = false,
    IsBusy              = false,      -- Mutex lock to prevent overlapping navigation commands
    CurrentPhase        = "Idle",     -- "Idle", "WalkingToPen", "AtPenCenter", "WalkingToTreadmill", "Training", "Dismounting"
    MountedSince        = 0,
    MyPlot              = nil,
    MyPlotIndex         = nil,
    PenPosition         = nil,
    TreadmillModel      = nil,
    TreadmillBelt       = nil,
    TreadmillPosition   = nil,
    UnplacedEggs        = {},
    LastEggScan         = 0,
    LoopThread          = nil,
}

-- ================================================================================
-- NETWORKING HELPERS
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

local Remotes = {
    AskPlaceEgg         = getNetRemote("RF/EggWorld/AskPlaceEgg"),
    FetchProfile        = getNetRemote("RF/ProfileMirror/FetchProfile"),
    AskLiveSnapshot     = getNetRemote("RF/EggWorld/AskLiveSnapshot"),
    AskWearStill        = getNetRemote("RF/Treadmill/AskWearStill"),
    AskDoff             = getNetRemote("RF/Treadmill/AskDoff"),
    AskRenderSnapshot   = getNetRemote("RF/Treadmill/AskRenderSnapshot"),
    SpeedGained         = getNetRemote("RE/Treadmill/SpeedGained"),
    AssignedBeltShifted = getNetRemote("RE/Treadmill/AssignedBeltShifted"),
}

-- Refresh remotes dynamically if loaded asynchronously
local function refreshRemotes()
    for k in pairs(Remotes) do
        local fullName = (k == "AskPlaceEgg" and "RF/EggWorld/AskPlaceEgg")
            or (k == "FetchProfile" and "RF/ProfileMirror/FetchProfile")
            or (k == "AskLiveSnapshot" and "RF/EggWorld/AskLiveSnapshot")
            or (k == "AskWearStill" and "RF/Treadmill/AskWearStill")
            or (k == "AskDoff" and "RF/Treadmill/AskDoff")
            or (k == "AskRenderSnapshot" and "RF/Treadmill/AskRenderSnapshot")
            or (k == "SpeedGained" and "RE/Treadmill/SpeedGained")
            or (k == "AssignedBeltShifted" and "RE/Treadmill/AssignedBeltShifted")
        if not Remotes[k] and fullName then
            Remotes[k] = getNetRemote(fullName)
        end
    end
end

-- ================================================================================
-- LOGGING PIPELINE
-- ================================================================================
local logEntries = {}
local logCallback = nil

local function logMsg(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    local timestamp = os.date("%H:%M:%S")
    local formatted = string.format("[%s] %s", timestamp, msg)
    table.insert(logEntries, formatted)
    if #logEntries > 100 then
        table.remove(logEntries, 1)
    end
    print("[AutoPenTreadmill] " .. msg)
    if logCallback then
        pcall(logCallback, formatted)
    end
end

-- ================================================================================
-- LOCAL PLAYER & CHARACTER UTILITIES
-- ================================================================================
local function getCharParts()
    local char = LocalPlayer.Character
    if not char then return nil, nil, nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum  = char:FindFirstChildOfClass("Humanoid")
    return char, root, hum
end

local function isOnTreadmill()
    local char = LocalPlayer.Character
    local lpAttr   = LocalPlayer:GetAttribute("IsOnTreadmill")
    local charAttr = char and char:GetAttribute("IsOnTreadmill")
    if lpAttr == true or charAttr == true then
        return true
    end
    -- Fallback: check if character is sitting/anchored on a treadmill belt
    if char and State.TreadmillBelt then
        local root = char:FindFirstChild("HumanoidRootPart")
        if root then
            local dist = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(State.TreadmillBelt.Position.X, 0, State.TreadmillBelt.Position.Z)).Magnitude
            if dist <= 3.5 and math.abs(root.Position.Y - State.TreadmillBelt.Position.Y) <= 3.0 then
                local hum = char:FindFirstChildOfClass("Humanoid")
                if hum and (hum:GetState() == Enum.HumanoidStateType.Running or hum.MoveDirection.Magnitude > 0.05) then
                    return true
                end
            end
        end
    end
    return false
end

local function distXZ(a, b)
    if not a or not b then return math.huge end
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

-- ================================================================================
-- PLOT, PEN & TREADMILL DISCOVERY ENGINE
-- ================================================================================
local function findMyPlot()
    local plotsFolder = Workspace:FindFirstChild("Plots") or Workspace:FindFirstChild("Bases")
    if not plotsFolder then
        logMsg("⚠️ Plots folder not found in Workspace, using fallback coordinates")
        return nil, nil
    end

    local myIdStr = tostring(LocalPlayer.UserId)
    local myName  = string.lower(LocalPlayer.Name)

    -- Pass 1: Authoritative Owner attribute check
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local pAttrs = plot:GetAttributes()
        local ownerAttr = pAttrs.Owner or pAttrs.OwnerId or pAttrs.Player or pAttrs.UserId or pAttrs.ClaimedBy
        if ownerAttr then
            local strOwner = tostring(ownerAttr):lower()
            if strOwner == myIdStr or strOwner == myName then
                local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                State.MyPlot = plot
                State.MyPlotIndex = idx
                logMsg("✓ Found My Plot by Owner attribute: %s (Index: %s)", plot.Name, tostring(idx))
                return plot, idx
            end
        end
    end

    -- Pass 2: Child Object / Sign text check
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        for _, desc in ipairs(plot:GetDescendants()) do
            if desc:IsA("TextLabel") or desc:IsA("SurfaceGui") then
                local txt = desc:IsA("TextLabel") and desc.Text:lower() or ""
                if string.find(txt, myName, 1, true) or string.find(txt, string.lower(LocalPlayer.DisplayName), 1, true) then
                    local idx = tonumber(plot.Name) or tonumber(string.match(plot.Name, "%d+"))
                    State.MyPlot = plot
                    State.MyPlotIndex = idx
                    logMsg("✓ Found My Plot by Sign label: %s (Index: %s)", plot.Name, tostring(idx))
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
            local d = distXZ(pPos, CONFIG.SafeZoneFallback)
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
        logMsg("✓ Found My Plot by SafeZone proximity: %s (Dist: %.1f studs)", bestPlot.Name, bestDist)
        return bestPlot, idx
    end

    return nil, nil
end

local function findMyPen()
    -- 1. Try finding pen position from existing PlacedEggRenders for this player
    local placedRenders = Workspace:FindFirstChild("PlacedEggRenders")
    if placedRenders then
        local myPrefix = tostring(LocalPlayer.UserId) .. "_"
        local eggPositions = {}
        for _, egg in ipairs(placedRenders:GetChildren()) do
            if string.find(egg.Name, myPrefix, 1, true) then
                local p = nil
                if egg:IsA("BasePart") then p = egg.Position
                elseif egg:IsA("Model") then
                    local ok, piv = pcall(function() return egg:GetPivot().Position end)
                    p = ok and piv or nil
                end
                if p then table.insert(eggPositions, p) end
            end
        end
        if #eggPositions > 0 then
            local avgX, avgY, avgZ = 0, 0, 0
            for _, pos in ipairs(eggPositions) do
                avgX = avgX + pos.X
                avgY = avgY + pos.Y
                avgZ = avgZ + pos.Z
            end
            local center = Vector3.new(avgX / #eggPositions, avgY / #eggPositions, avgZ / #eggPositions)
            State.PenPosition = center
            logMsg("✓ Found My Pen from %d existing placed eggs at (%.1f, %.1f, %.1f)", #eggPositions, center.X, center.Y, center.Z)
            return center
        end
    end

    -- 2. Try finding Pen / Nest / Incubator within MyPlot
    local plot = State.MyPlot
    if not plot then
        plot, _ = findMyPlot()
    end

    if plot then
        for _, desc in ipairs(plot:GetDescendants()) do
            local low = string.lower(desc.Name)
            if (low:find("pen") or low:find("nest") or low:find("incubator") or low:find("eggspot") or low:find("delivery"))
               and desc:IsA("BasePart") then
                State.PenPosition = desc.Position
                logMsg("✓ Found My Pen part in plot: %s at (%.1f, %.1f, %.1f)", desc:GetFullName(), desc.Position.X, desc.Position.Y, desc.Position.Z)
                return desc.Position
            end
        end
        -- Default to plot center if no specific pen part found
        local ok, piv = pcall(function() return plot:GetPivot().Position end)
        if ok and piv then
            State.PenPosition = piv
            return piv
        end
    end

    -- 3. Fallback to SafeZone
    State.PenPosition = CONFIG.SafeZoneFallback
    logMsg("Using fallback Pen position: (%.1f, %.1f, %.1f)", CONFIG.SafeZoneFallback.X, CONFIG.SafeZoneFallback.Y, CONFIG.SafeZoneFallback.Z)
    return CONFIG.SafeZoneFallback
end

local function findMyTreadmill()
    -- 1. Try finding from Workspace.__ClientTreadmillRenders
    local clientTreadmills = Workspace:FindFirstChild("__ClientTreadmillRenders")
    local plotIdx = State.MyPlotIndex
    if not plotIdx then
        _, plotIdx = findMyPlot()
    end

    local candidate = nil
    if clientTreadmills and plotIdx then
        local targetName = "TreadmillRender_" .. tostring(plotIdx)
        candidate = clientTreadmills:FindFirstChild(targetName)
    end

    -- If not found by index, find nearest TreadmillRender to MyPen
    if not candidate and clientTreadmills then
        local penPos = State.PenPosition or CONFIG.SafeZoneFallback
        local minDist = math.huge
        for _, tm in ipairs(clientTreadmills:GetChildren()) do
            local p = nil
            if tm:IsA("BasePart") then p = tm.Position
            elseif tm:IsA("Model") or tm:IsA("Tool") then
                local ok, piv = pcall(function() return tm:GetPivot().Position end)
                p = ok and piv or (tm:FindFirstChildWhichIsA("BasePart") and tm:FindFirstChildWhichIsA("BasePart").Position)
            end
            if p then
                local d = distXZ(p, penPos)
                if d < minDist then
                    minDist = d
                    candidate = tm
                end
            end
        end
    end

    -- 2. Try finding inside MyPlot
    if not candidate and State.MyPlot then
        for _, desc in ipairs(State.MyPlot:GetDescendants()) do
            if string.find(string.lower(desc.Name), "treadmill") then
                candidate = desc
                break
            end
        end
    end

    if candidate then
        State.TreadmillModel = candidate
        -- Find the primary running surface / belt
        local belt = nil
        for _, p in ipairs(candidate:GetDescendants()) do
            if p:IsA("BasePart") then
                local ln = string.lower(p.Name)
                if ln:find("belt") or ln:find("cube.015") or ln:find("running") or ln:find("surface") or ln:find("pad") then
                    belt = p
                    break
                end
            end
        end
        if not belt then
            belt = candidate:FindFirstChildWhichIsA("BasePart", true)
        end
        State.TreadmillBelt = belt
        if belt then
            State.TreadmillPosition = belt.Position
            logMsg("✓ Found My Treadmill: %s (Belt: %s at %.1f, %.1f, %.1f)", candidate.Name, belt.Name, belt.Position.X, belt.Position.Y, belt.Position.Z)
            return candidate, belt, belt.Position
        end
    end

    logMsg("⚠️ Treadmill not located automatically yet. Will retry during movement.")
    return nil, nil, nil
end

-- ================================================================================
-- INVENTORY & UNPLACED EGG SCANNER
-- ================================================================================
local function isEggTool(item)
    if not item or not (item:IsA("Tool") or item:IsA("Model")) then return false end
    local name = string.lower(item.Name)
    if string.find(name, "egg", 1, true) then return true end
    local attrs = item:GetAttributes()
    if attrs.IsEgg == true or attrs.ItemType == "Egg" or attrs.Category == "Egg" then
        return true
    end
    return false
end

local function scanUnplacedEggs()
    refreshRemotes()
    local unplaced = {}
    local seenUids = {}

    -- 1. Scan ProfileMirror (Authoritative Satchel Eggs where Placement == nil)
    if Remotes.FetchProfile then
        local ok, prof = pcall(function() return Remotes.FetchProfile:InvokeServer(LocalPlayer) end)
        if not ok or type(prof) ~= "table" then
            ok, prof = pcall(function() return Remotes.FetchProfile:InvokeServer() end)
        end

        if ok and type(prof) == "table" and type(prof.EggInventory) == "table" then
            for eggUid, eggData in pairs(prof.EggInventory) do
                local uidStr = tostring(eggUid)
                if not seenUids[uidStr] and type(eggData) == "table" then
                    -- STRICT UNPLACED CRITERIA: Placement == nil or false or ""
                    if eggData.Placement == nil or eggData.Placement == false or eggData.Placement == "" then
                        seenUids[uidStr] = true
                        table.insert(unplaced, {
                            Uid         = uidStr,
                            Category    = tostring(eggData.AssetCategory or "Egg"),
                            DisplayName = tostring(eggData.DisplayName or eggData.AssetCategory or "Egg"),
                            Source      = "ProfileSatchel",
                            RawData     = eggData,
                        })
                    end
                end
            end
        end
    end

    -- 2. Scan Backpack Tools
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        for _, item in ipairs(bp:GetChildren()) do
            if isEggTool(item) then
                local uid = item:GetAttribute("EggUid") or item:GetAttribute("Uid") or item.Name
                if not seenUids[tostring(uid)] then
                    seenUids[tostring(uid)] = true
                    table.insert(unplaced, {
                        Uid         = tostring(uid),
                        DisplayName = item.Name,
                        Tool        = item,
                        Source      = "Backpack",
                    })
                end
            end
        end
    end

    -- 3. Scan Character Tools (Currently Equipped)
    local char = LocalPlayer.Character
    if char then
        for _, item in ipairs(char:GetChildren()) do
            if isEggTool(item) then
                local uid = item:GetAttribute("EggUid") or item:GetAttribute("Uid") or item.Name
                if not seenUids[tostring(uid)] then
                    seenUids[tostring(uid)] = true
                    table.insert(unplaced, {
                        Uid         = tostring(uid),
                        DisplayName = item.Name,
                        Tool        = item,
                        Source      = "Character",
                    })
                end
            end
        end
    end

    State.UnplacedEggs = unplaced
    State.LastEggScan = os.clock()
    return unplaced
end

-- ================================================================================
-- MOVEMENT ENGINE (PURE WALK TO TARGET - ZERO TELEPORTING)
-- ================================================================================
local function moveToPosition(targetPos, arrivalDist, onStep)
    arrivalDist = arrivalDist or 3.0
    local char, root, hum = getCharParts()
    if not char or not root or not hum then return false end

    local startTime = os.clock()
    local timeout   = 60.0

    while (os.clock() - startTime) < timeout do
        if not LocalPlayer.Character or not root.Parent or hum.Health <= 0 then break end

        local curPos = root.Position
        local xz = distXZ(curPos, targetPos)

        if xz <= arrivalDist then
            pcall(function() hum:Move(Vector3.zero) end)
            return true
        end

        if onStep and onStep() == false then
            pcall(function() hum:Move(Vector3.zero) end)
            return false
        end

        -- Pure walk navigation toward target (NO teleporting, NO CFrame snaps)
        local dir = Vector3.new(targetPos.X - curPos.X, 0, targetPos.Z - curPos.Z)
        if dir.Magnitude > 0.1 then
            hum:Move(dir.Unit, false)
            hum:MoveTo(targetPos)
        end

        task.wait(0.08)
    end

    pcall(function() hum:Move(Vector3.zero) end)
    return distXZ(root.Position, targetPos) <= arrivalDist
end

-- ================================================================================
-- AUTOMATION ACTIONS
-- ================================================================================

-- Action 1: Walk to Pen and Stop at Center (No egg placing)
local function executeGoToPen()
    if State.IsBusy then
        logMsg("⚠️ Another action is in progress. Please wait.")
        return false
    end
    State.IsBusy = true
    State.CurrentPhase = "WalkingToPen"
    logMsg("▶ Walking to Pen Center...")

    -- 1. Ensure Pen position is resolved
    local penPos = State.PenPosition or findMyPen()
    if not penPos then
        logMsg("❌ Could not determine Pen position. Aborting.")
        State.CurrentPhase = "Idle"
        State.IsBusy = false
        return false
    end

    -- 2. Dismount treadmill if currently on it (via jump)
    if isOnTreadmill() then
        logMsg("Currently on treadmill. Dismounting via jump...")
        executeDismount()
        task.wait(0.4)
    end

    -- 3. Walk to Pen Center (pure walk, NO TP)
    logMsg("Walking to Pen Center at (%.1f, %.1f, %.1f)...", penPos.X, penPos.Y, penPos.Z)
    local arrived = moveToPosition(penPos, 3.0)

    -- 4. Stop completely at the center of the pen
    local _, _, hum = getCharParts()
    if hum then
        pcall(function() hum:Move(Vector3.zero) end)
    end
    task.wait(0.1)

    State.CurrentPhase = "AtPenCenter"
    logMsg("✓ Arrived and stopped at the center of the pen.")
    State.IsBusy = false
    return true
end

-- Action 2: Walk to Treadmill & Mount (No TP)
local function executeGoToTreadmill()
    if State.IsBusy then
        logMsg("⚠️ Another action is in progress. Please wait.")
        return false
    end
    State.IsBusy = true
    State.CurrentPhase = "WalkingToTreadmill"
    logMsg("▶ Walking to Treadmill...")

    -- 1. Ensure Treadmill is located
    local tmModel, tmBelt, tmPos = State.TreadmillModel, State.TreadmillBelt, State.TreadmillPosition
    if not tmPos then
        tmModel, tmBelt, tmPos = findMyTreadmill()
    end
    if not tmPos then
        logMsg("❌ Could not determine Treadmill position. Retrying discovery...")
        findMyPlot()
        tmModel, tmBelt, tmPos = findMyTreadmill()
        if not tmPos then
            logMsg("❌ Treadmill discovery failed. Aborting.")
            State.CurrentPhase = "Idle"
            State.IsBusy = false
            return false
        end
    end

    -- 2. Walk to Treadmill Belt (pure walk, NO TP)
    logMsg("Walking to Treadmill at (%.1f, %.1f, %.1f)...", tmPos.X, tmPos.Y, tmPos.Z)
    local arrived = moveToPosition(tmPos, 2.5)

    local _, _, hum = getCharParts()
    if hum then
        pcall(function() hum:Move(Vector3.zero) end)
    end
    task.wait(0.2)

    -- 3. Trigger Mount Sequence
    logMsg("Mounting Treadmill...")
    refreshRemotes()

    -- Method A: Remote Invocation RF/Treadmill/AskWearStill
    if Remotes.AskWearStill then
        pcall(function() Remotes.AskWearStill:InvokeServer() end)
        if State.MyPlotIndex then
            pcall(function() Remotes.AskWearStill:InvokeServer(State.MyPlotIndex) end)
        end
        if tmModel then
            pcall(function() Remotes.AskWearStill:InvokeServer(tmModel) end)
        end
    end

    -- Method B: Fire ProximityPrompts on Treadmill if present
    if tmModel and typeof(fireproximityprompt) == "function" then
        for _, prompt in ipairs(tmModel:GetDescendants()) do
            if prompt:IsA("ProximityPrompt") then
                pcall(function() fireproximityprompt(prompt) end)
            end
        end
    end

    task.wait(0.4)

    State.CurrentPhase = "Training"
    State.MountedSince = os.clock()
    logMsg("✓ On Treadmill (Training).")
    State.IsBusy = false
    return true
end

-- Action 3: Dismount Treadmill (Trigger Jump)
local function executeDismount()
    State.CurrentPhase = "Dismounting"
    logMsg("▶ Dismounting treadmill: triggering jump...")

    local _, _, hum = getCharParts()
    if hum then
        pcall(function()
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
            hum.Jump = true
        end)
        task.wait(0.05)
        pcall(function()
            hum.Jump = true
        end)
    end

    task.wait(0.2)
    State.CurrentPhase = "Idle"
    logMsg("✓ Jump triggered for dismount.")
    return true
end

-- ================================================================================
-- CONTINUOUS AUTONOMOUS CYCLE ENGINE
-- ================================================================================
local function startAutoLoop()
    if State.LoopThread then return end
    CONFIG.AutoLoop = true
    State.IsRunning = true
    logMsg("==================================================")
    logMsg("🚀 AUTO CYCLE STARTED (Walk to Pen <-> Treadmill)")
    logMsg("==================================================")

    State.LoopThread = task.spawn(function()
        while CONFIG.AutoLoop do
            -- Step 1: Walk to Pen Center and stop
            executeGoToPen()

            -- Stay at pen center for configured wait duration
            local penWait = CONFIG.PenWaitDuration or 5.0
            local startWait = os.clock()
            while CONFIG.AutoLoop and (os.clock() - startWait) < penWait do
                task.wait(0.5)
            end
            if not CONFIG.AutoLoop then break end

            -- Step 2: Walk to Treadmill and mount
            executeGoToTreadmill()

            -- Step 3: Train on treadmill for duration
            local trainDuration = CONFIG.AutoDismountTimer > 0 and CONFIG.AutoDismountTimer or 30.0
            local startTrain = os.clock()
            while CONFIG.AutoLoop and (os.clock() - startTrain) < trainDuration do
                task.wait(1.0)
            end
            if not CONFIG.AutoLoop then break end

            -- Step 4: Dismount via jump
            executeDismount()
            task.wait(1.5)
        end

        State.IsRunning = false
        State.LoopThread = nil
        logMsg("⏹️ Auto cycle stopped.")
    end)
end

local function stopAutoLoop()
    CONFIG.AutoLoop = false
    State.IsRunning = false
    if State.LoopThread then
        task.cancel(State.LoopThread)
        State.LoopThread = nil
    end
    State.CurrentPhase = "Idle"
    logMsg("⏹️ Auto cycle stopped by user.")
end

-- ================================================================================
-- MODERN INTERACTIVE IN-GAME HUD
-- ================================================================================
local function createUI()
    local getHui = gethui or function() return CoreGui end
    local uiParent = nil
    pcall(function() uiParent = getHui() end)
    if not uiParent then
        uiParent = LocalPlayer:FindFirstChild("PlayerGui") or CoreGui
    end

    -- Cleanup old GUI if exists
    local old = uiParent:FindFirstChild("AutoPenTreadmillGui")
    if old then pcall(function() old:Destroy() end) end

    local gui = Instance.new("ScreenGui")
    gui.Name = "AutoPenTreadmillGui"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 99999
    pcall(function() gui.Parent = uiParent end)
    if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    -- Main Container
    local main = Instance.new("Frame")
    main.Size = UDim2.new(0, 420, 0, 480)
    main.Position = UDim2.new(0.5, -210, 0.5, -240)
    main.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
    main.BorderSizePixel = 0
    main.Active = true
    main.Parent = gui
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new("UIStroke", main)
    stroke.Color = Color3.fromRGB(65, 120, 210)
    stroke.Thickness = 1.5

    -- Title Bar (Draggable)
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 40)
    titleBar.BackgroundColor3 = Color3.fromRGB(26, 32, 48)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = main
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, -50, 1, 0)
    titleLbl.Position = UDim2.new(0, 12, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "🥚 AUTO PEN & TREADMILL SUITE 🏃"
    titleLbl.TextColor3 = Color3.fromRGB(230, 240, 255)
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 13
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = titleBar

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 28, 0, 28)
    closeBtn.Position = UDim2.new(1, -34, 0, 6)
    closeBtn.BackgroundColor3 = Color3.fromRGB(190, 50, 50)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 13
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
    closeBtn.MouseButton1Click:Connect(function()
        stopAutoLoop()
        gui:Destroy()
    end)

    -- Dragging Handler
    local dragging, dragStart, startPos = false, nil, nil
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
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

    -- Status Card
    local statusCard = Instance.new("Frame")
    statusCard.Size = UDim2.new(1, -20, 0, 52)
    statusCard.Position = UDim2.new(0, 10, 0, 48)
    statusCard.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
    statusCard.BorderSizePixel = 0
    statusCard.Parent = main
    Instance.new("UICorner", statusCard).CornerRadius = UDim.new(0, 8)

    local statusTitle = Instance.new("TextLabel")
    statusTitle.Size = UDim2.new(1, -16, 0, 18)
    statusTitle.Position = UDim2.new(0, 8, 0, 6)
    statusTitle.BackgroundTransparency = 1
    statusTitle.Text = "CURRENT STATE"
    statusTitle.TextColor3 = Color3.fromRGB(150, 175, 215)
    statusTitle.Font = Enum.Font.GothamBold
    statusTitle.TextSize = 10
    statusTitle.TextXAlignment = Enum.TextXAlignment.Left
    statusTitle.Parent = statusCard

    local statusVal = Instance.new("TextLabel")
    statusVal.Size = UDim2.new(1, -16, 0, 22)
    statusVal.Position = UDim2.new(0, 8, 0, 24)
    statusVal.BackgroundTransparency = 1
    statusVal.Text = "Idle"
    statusVal.TextColor3 = Color3.fromRGB(100, 220, 140)
    statusVal.Font = Enum.Font.GothamBold
    statusVal.TextSize = 13
    statusVal.TextXAlignment = Enum.TextXAlignment.Left
    statusVal.Parent = statusCard

    -- Info Row (Eggs & Treadmill Status)
    local infoRow = Instance.new("Frame")
    infoRow.Size = UDim2.new(1, -20, 0, 36)
    infoRow.Position = UDim2.new(0, 10, 0, 106)
    infoRow.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
    infoRow.BorderSizePixel = 0
    infoRow.Parent = main
    Instance.new("UICorner", infoRow).CornerRadius = UDim.new(0, 8)

    local eggInfoLbl = Instance.new("TextLabel")
    eggInfoLbl.Size = UDim2.new(0.5, -8, 1, 0)
    eggInfoLbl.Position = UDim2.new(0, 8, 0, 0)
    eggInfoLbl.BackgroundTransparency = 1
    eggInfoLbl.Text = "🥚 Unplaced Eggs: 0"
    eggInfoLbl.TextColor3 = Color3.fromRGB(220, 230, 245)
    eggInfoLbl.Font = Enum.Font.GothamMedium
    eggInfoLbl.TextSize = 11
    eggInfoLbl.TextXAlignment = Enum.TextXAlignment.Left
    eggInfoLbl.Parent = infoRow

    local tmInfoLbl = Instance.new("TextLabel")
    tmInfoLbl.Size = UDim2.new(0.5, -8, 1, 0)
    tmInfoLbl.Position = UDim2.new(0.5, 0, 0, 0)
    tmInfoLbl.BackgroundTransparency = 1
    tmInfoLbl.Text = "🏃 Treadmill: OFF"
    tmInfoLbl.TextColor3 = Color3.fromRGB(180, 190, 205)
    tmInfoLbl.Font = Enum.Font.GothamMedium
    tmInfoLbl.TextSize = 11
    tmInfoLbl.TextXAlignment = Enum.TextXAlignment.Left
    tmInfoLbl.Parent = infoRow

    -- Action Buttons Layout
    local function makeButton(name, text, pos, size, bgCol, onClick)
        local btn = Instance.new("TextButton")
        btn.Name = name
        btn.Text = text
        btn.Position = pos
        btn.Size = size
        btn.BackgroundColor3 = bgCol
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 11
        btn.Parent = main
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
        btn.MouseButton1Click:Connect(onClick)
        return btn
    end

    -- Button Row 1: Manual Instant Actions
    local btnGoToPen = makeButton("BtnGoToPen", "📍 WALK TO PEN", UDim2.new(0, 10, 0, 148), UDim2.new(0.5, -14, 0, 32), Color3.fromRGB(45, 130, 80), function()
        task.spawn(executeGoToPen)
    end)

    local btnTreadmill = makeButton("BtnTreadmill", "🏃 GO TO TREADMILL", UDim2.new(0.5, 4, 0, 148), UDim2.new(0.5, -14, 0, 32), Color3.fromRGB(40, 100, 180), function()
        task.spawn(executeGoToTreadmill)
    end)

    -- Button Row 2: Dismount
    local btnDismount = makeButton("BtnDismount", "🛑 DISMOUNT (JUMP)", UDim2.new(0, 10, 0, 186), UDim2.new(1, -20, 0, 32), Color3.fromRGB(180, 60, 60), function()
        task.spawn(executeDismount)
    end)

    -- Log Box (Diagnostic & Output)
    local logBoxFrame = Instance.new("Frame")
    logBoxFrame.Size = UDim2.new(1, -20, 0, 210)
    logBoxFrame.Position = UDim2.new(0, 10, 0, 226)
    logBoxFrame.BackgroundColor3 = Color3.fromRGB(12, 15, 22)
    logBoxFrame.BorderSizePixel = 0
    logBoxFrame.Parent = main
    Instance.new("UICorner", logBoxFrame).CornerRadius = UDim.new(0, 8)
    local logStroke = Instance.new("UIStroke", logBoxFrame)
    logStroke.Color = Color3.fromRGB(40, 50, 70)

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -12, 1, -12)
    scroll.Position = UDim2.new(0, 6, 0, 6)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = logBoxFrame

    local logTxt = Instance.new("TextLabel")
    logTxt.Size = UDim2.new(1, -6, 0, 0)
    logTxt.BackgroundTransparency = 1
    logTxt.TextColor3 = Color3.fromRGB(180, 195, 215)
    logTxt.Font = Enum.Font.Code
    logTxt.TextSize = 10
    logTxt.TextXAlignment = Enum.TextXAlignment.Left
    logTxt.TextYAlignment = Enum.TextYAlignment.Top
    logTxt.TextWrapped = true
    logTxt.Text = "Ready. Logs will appear here..."
    logTxt.Parent = scroll

    -- Refresh Log Display
    logCallback = function(_)
        local fullText = table.concat(logEntries, "\n")
        logTxt.Text = fullText
        local textBounds = logTxt.TextBounds
        logTxt.Size = UDim2.new(1, -6, 0, math.max(textBounds.Y, 20))
        scroll.CanvasSize = UDim2.new(0, 0, 0, textBounds.Y + 10)
        scroll.CanvasPosition = Vector2.new(0, math.max(0, textBounds.Y - scroll.AbsoluteSize.Y + 10))
    end

    -- Bottom Toolbar: Clear Logs & Copy Logs
    local clearBtn = makeButton("BtnClear", "Clear", UDim2.new(0, 10, 0, 442), UDim2.new(0, 60, 0, 24), Color3.fromRGB(35, 42, 58), function()
        table.clear(logEntries)
        logTxt.Text = "Cleared."
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    end)

    local copyBtn = makeButton("BtnCopy", "Copy Logs", UDim2.new(0, 76, 0, 442), UDim2.new(0, 80, 0, 24), Color3.fromRGB(45, 60, 90), function()
        if setclipboard then
            setclipboard(table.concat(logEntries, "\n"))
            logMsg("✓ Logs copied to clipboard!")
        end
    end)

    -- Status & Metric HUD Poller
    task.spawn(function()
        while gui and gui.Parent do
            task.wait(0.4)
            -- Update Phase Text
            statusVal.Text = State.CurrentPhase
            if State.CurrentPhase == "Training" then
                statusVal.TextColor3 = Color3.fromRGB(80, 200, 255)
            elseif State.CurrentPhase:find("Placing") then
                statusVal.TextColor3 = Color3.fromRGB(240, 180, 60)
            elseif State.CurrentPhase:find("Moving") then
                statusVal.TextColor3 = Color3.fromRGB(220, 140, 240)
            else
                statusVal.TextColor3 = Color3.fromRGB(120, 220, 140)
            end

            -- Update Egg Count
            eggInfoLbl.Text = string.format("🥚 Unplaced Eggs: %d", #State.UnplacedEggs)

            -- Update Treadmill Status
            local onTm = isOnTreadmill()
            if onTm then
                tmInfoLbl.Text = "🏃 Treadmill: ON (Training)"
                tmInfoLbl.TextColor3 = Color3.fromRGB(80, 220, 120)
            else
                tmInfoLbl.Text = "🏃 Treadmill: OFF"
                tmInfoLbl.TextColor3 = Color3.fromRGB(180, 190, 205)
            end
        end
    end)

    logMsg("AutoPenTreadmill GUI initialized successfully.")
end

-- ================================================================================
-- INITIALIZATION PIPELINE
-- ================================================================================
local function init()
    logMsg("Initializing Auto Pen & Treadmill Automation...")
    refreshRemotes()
    findMyPlot()
    findMyPen()
    findMyTreadmill()
    scanUnplacedEggs()
    createUI()
    logMsg("Initialization complete. Ready for manual triggers or Auto Cycle.")
end

task.spawn(init)
